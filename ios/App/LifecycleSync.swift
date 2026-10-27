import Foundation
import UserNotifications

/// Turns order states read off the delivery apps' screens (LifecycleSignal from the offer reader) into trip steps.
/// Works with the GPS detector: whichever sees a step first records it; the other finds nothing left to do. Off when
/// "Tick order steps automatically" is off.
///
/// When an offer counts as accepted — explicit rules (user, Oct 18: "Shouldn't there be logical rules in place?" after
/// declined offers were marked accepted minutes later). When the evidence is unclear, __APP_NAME__ asks instead of guessing.
/// 1. Offers expire: without the store on screen, only a pickup screen within 4 minutes of the offer accepts it.
/// 2. The store must match: a pickup screen that names its store accepts only the offer from that store (within 30
///    minutes); a different store accepts nothing.
/// 3. Only pickup screens (heading to / at the store) accept. Customer-side screens never create an order: they move an
///    existing one, and for an order __APP_NAME__ doesn't know they send a "did __APP_NAME__ miss one?" notification.
/// 4. No choosing: without a store on screen, more than one recent offer from that app means no accept — unless the
///    newest one is under 2 minutes old and nothing came after it (Oct 26): that's the card just accepted.
/// 5. A passed offer stays passed: once the app is back to waiting for offers, or shows a newer offer, an older one is
///    accepted only through its store on a pickup screen.
/// 6. Another app's order in progress: a screen "for" an app with no order is likely a misread — no store, no accept.
/// 7. One match only (Oct 22): a store code that fits more than one recent offer accepts only the newest of them, and only
///    if no other offer from that app came after it (Oct 26: busy shifts repeat stores — Cafe Zupas, Chipotle, Potbelly
///    each had an earlier offer, and no order of the shift was caught).
/// 8. A removed order stays removed (Oct 22: New York Slices came back 5 times after being deleted): an offer whose order
///    was removed is never accepted from a screen again, nor is any other offer from that store for 30 minutes.
/// A screen past a step that wasn't seen (e.g. "heading to the customer" without "left the store") fills that step in
/// at low confidence, so its timing isn't used for learning but the trip keeps moving.
@MainActor
final class LifecycleSync {
    static let shared = LifecycleSync()
    weak var model: AppModel?
    private var lastState: [String: String] = [:]
    /// When each app was last seen waiting for offers: an offer shown before that was passed on.
    private var lastAvailable: [String: Date] = [:]
    private var lastMissedPrompt: [String: Date] = [:]

    static let offerLifetime: TimeInterval = 240
    static let storeMatchWindow: TimeInterval = 1800

    func received(_ signal: LifecycleSignal, at now: Date = Date()) {
        let previous = lastState[signal.platform]
        lastState[signal.platform] = signal.state
        if signal.state == "available" { lastAvailable[signal.platform] = now }
        guard AutoSteps.isEnabled else { return }
        let p = signal.platform
        let otherAppBusy = !hasOpenOrder(p) && (TripStore.shared.active?.orders.contains { $0.ended == nil && $0.platform != p } ?? false)
        switch signal.state {
        case "heading_to_store":
            if step(.leftStore, p, now, inferred: false) { return }   // Off to the next store of a multi-store order.
            acceptFromPickupScreen(p, store: signal.store, now, otherAppBusy: otherAppBusy)
        case "navigating_to_store":
            step(.leftStore, p, now, inferred: false)   // Driving away from a store you're at; never an accept.
        case "at_store":
            acceptFromPickupScreen(p, store: signal.store, now, otherAppBusy: otherAppBusy)
            arriveAtStore(p, store: signal.store, now)
        case "heading_to_customer":
            if !hasOpenOrder(p) { promptMissedOrder(p, now, otherAppBusy: otherAppBusy); return }
            fillPickup(p, now)
        case "at_customer":
            if !hasOpenOrder(p) { promptMissedOrder(p, now, otherAppBusy: otherAppBusy); return }
            if atStore(p) { return }
            fillPickup(p, now)
            step(.arrivedDropoff, p, now, inferred: false)
        case "delivered":
            // Never while you're at a store you haven't left (user, Oct 27: the last customer's messages said
            // "delivered" at JimmyJohn's and completed the new order). Leaving the store comes first.
            if atStore(p) { return }
            fillPickup(p, now)
            step(.arrivedDropoff, p, now, inferred: true)
            step(.delivered, p, now, inferred: false)
        case "available":
            // Back to waiting for offers right after the drop-off: that delivery is done.
            if previous == "at_customer" { step(.delivered, p, now, inferred: true) }
        default:
            break
        }
    }

    // MARK: Accepting (rules 1–6 above)

    private func acceptFromPickupScreen(_ platform: String, store: Int?, _ now: Date, otherAppBusy: Bool) {
        if let store {
            // Rule 2: the screen names its store. An open order at that store is this screen's order; else the offer from
            // that store, if there is one.
            if openOrderShows(store, platform) { return }
            if TripStore.shared.recentlyRemovedStores(platform, now: now).contains(store) { return }
            let matches = candidates(platform, now, within: Self.storeMatchWindow).filter { Self.storeCodes($0).contains(store) }
            // The same card read twice is one offer. Several offers with this code (Oct 26: every order of the shift had
            // an earlier offer from the same store, so none was caught): the newest, if no other offer from the app came
            // after it — the app only lets you accept the card on screen, so the older ones were passed (rule 5).
            if let offer = matches.last, Set(matches.map { $0.offerId ?? $0.id }).count == 1 { accept(offer, now) }
            else if let newest = matches.max(by: { $0.seenAt < $1.seenAt }), isNewestOffer(newest) { accept(newest, now) }
            return
        }
        // No store on screen: rules 1, 4, 5, 6 — a fresh accept of the offer on screen, never a stack or a guess: the only
        // recent offer, or the newest one when it's under 2 minutes old (the card just accepted).
        guard !hasOpenOrder(platform), !otherAppBusy, pending(.arrivedStore, platform) == nil else { return }
        let recent = candidates(platform, now, within: Self.offerLifetime)
        guard let offer = recent.max(by: { $0.seenAt < $1.seenAt }), isNewestOffer(offer),
              recent.count == 1 || now.timeIntervalSince(offer.seenAt) < 120 else { return }
        accept(offer, now)
    }

    /// A full reading, not a partial "Check offer" read of the same card (those appear right after the real one).
    private static func isFullRead(_ offer: LiveOffer) -> Bool { offer.outboundMilliMiles != nil }

    /// Offers from `platform` that could still be accepted: recent, not taken, shown after the app last waited for offers.
    private func candidates(_ platform: String, _ now: Date, within window: TimeInterval) -> [LiveOffer] {
        (model?.offers ?? []).filter { offer in
            offer.platform == platform && Self.isFullRead(offer) && now.timeIntervalSince(offer.seenAt) < window
                && TripStore.shared.trip(for: offer.offerId ?? offer.id) == nil && !DemoData.isDemo(offer.offerId)
                && !TripStore.shared.wasRemoved(offer.offerId ?? offer.id)
                && offer.seenAt > (lastAvailable[platform] ?? .distantPast)
        }
    }

    /// No newer offer from that app has been shown since (rule 5).
    private func isNewestOffer(_ offer: LiveOffer) -> Bool {
        !(model?.offers ?? []).contains { $0.platform == offer.platform && Self.isFullRead($0) && $0.seenAt > offer.seenAt }
    }

    private static func storeCodes(_ offer: LiveOffer) -> Set<Int> {
        LifecycleSignal.storeCodes((offer.merchants ?? []) + [offer.merchant].compactMap { $0 })
    }

    private func openOrderShows(_ store: Int, _ platform: String) -> Bool {
        TripStore.shared.active?.orders.contains { order in
            order.platform == platform && order.ended == nil
                && LifecycleSignal.storeCodes(order.stores + [order.merchant].compactMap { $0 }).contains(store)
        } ?? false
    }

    private func accept(_ offer: LiveOffer, _ now: Date) {
        // Found late (minutes after the offer, by its store): it was accepted right after it was shown, not now.
        let late = now.timeIntervalSince(offer.seenAt) > 120
        TripStore.shared.accept(TripOfferInfo(offer), at: late ? offer.seenAt.addingTimeInterval(20) : now,
                                source: late ? "screen_late" : "screen")
    }

    /// Rule 3: a delivery screen for an order __APP_NAME__ doesn't have — ask, at most every 15 minutes per app, and not when
    /// another app's order is open (then it's most likely that app's screen misread).
    private func promptMissedOrder(_ platform: String, _ now: Date, otherAppBusy: Bool) {
        guard !otherAppBusy, now.timeIntervalSince(lastMissedPrompt[platform] ?? .distantPast) > 900 else { return }
        lastMissedPrompt[platform] = now
        let content = UNMutableNotificationContent()
        content.title = "Delivering a \(Theme.appName(platform)) order?"
        content.body = "__APP_NAME__ didn't catch it being accepted. Add it with ＋ so it counts."
        content.threadIdentifier = "trip"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "missed-order-\(platform)", content: content, trigger: nil))
    }

    // MARK: Steps

    /// A store's pickup screen: arrival at that store. Nothing when it's the store you're already at (user, Oct 22: the
    /// pickup screen at Mendocino Farms marked Raising Cane's, the next store, as arrived), or when the screen's store
    /// isn't one still to visit.
    private func arriveAtStore(_ platform: String, store: Int?, _ now: Date) {
        guard let trip = TripStore.shared.active else { return }
        let orders = trip.orders.filter { $0.platform == platform && $0.ended == nil }
        let pending = trip.actions.filter { action in action.kind == .arrivedStore && orders.contains { $0.offerId == action.offerId } }
        let storeName = { (action: TripAction) in orders.first { $0.offerId == action.offerId }.flatMap { $0.stores.indices.contains(action.stop) ? $0.stores[action.stop] : nil } }
        if let store {
            guard let action = pending.first(where: { LifecycleSignal.storeCode(storeName($0)) == store }) else { return }
            TripStore.shared.perform(action, at: now, auto: true, source: "screen")
            return
        }
        let atAStore = orders.contains { order in order.stores.indices.contains { trip.has(.arrivedStore, order.offerId, $0) && !trip.has(.leftStore, order.offerId, $0) } }
        guard !atAStore, let action = pending.first else { return }
        TripStore.shared.perform(action, at: now, auto: true, source: "screen")
    }

    /// Leaving the store(s) before heading to the customer; an arrival that wasn't seen is filled in too.
    private func fillPickup(_ platform: String, _ now: Date) {
        // Leave the store(s) you're at.
        for _ in 0..<6 where step(.leftStore, platform, now, inferred: true) {}
        // Heading to a customer means at least one pickup is done: fill in one unseen store only when none has been
        // left yet. With several stores the app can send you to a drop-off between them (user, Oct 22: DoorDash went
        // Mendocino Farms -> drop-off -> Raising Cane's, and Raising Cane's was marked arrived and left before you'd been there).
        guard let trip = TripStore.shared.active,
              let order = trip.orders.first(where: { $0.platform == platform && $0.ended == nil }),
              !order.stores.indices.contains(where: { trip.has(.leftStore, order.offerId, $0) }) else { return }
        if step(.arrivedStore, platform, now, inferred: true) { step(.leftStore, platform, now, inferred: true) }
    }

    /// The app's open order hasn't been picked up: you're at one of its stores and haven't left, or it's under 10 minutes
    /// old with no store reached yet. A customer-side screen then belongs to the order before it.
    private func atStore(_ platform: String, _ now: Date = Date()) -> Bool {
        guard let trip = TripStore.shared.active else { return false }
        return trip.orders.contains { order in
            guard order.platform == platform, order.ended == nil else { return false }
            let reached = order.stores.indices.filter { trip.has(.arrivedStore, order.offerId, $0) || trip.has(.leftStore, order.offerId, $0) }
            if reached.isEmpty { return now.timeIntervalSince(order.acceptedAt) < 600 }
            return reached.contains { !trip.has(.leftStore, order.offerId, $0) }
        }
    }

    private func hasOpenOrder(_ platform: String) -> Bool {
        TripStore.shared.active?.orders.contains { $0.platform == platform && $0.ended == nil } ?? false
    }

    private func pending(_ kind: Trip.StepKind, _ platform: String) -> TripAction? {
        guard let trip = TripStore.shared.active else { return nil }
        return trip.actions.first { action in
            action.kind == kind && trip.orders.contains { $0.offerId == action.offerId && $0.platform == platform }
        }
    }

    @discardableResult
    private func step(_ kind: Trip.StepKind, _ platform: String, _ now: Date, inferred: Bool) -> Bool {
        guard let action = pending(kind, platform) else { return false }
        TripStore.shared.perform(action, at: now, auto: true, source: inferred ? "screen_inferred" : "screen")
        return true
    }
}
