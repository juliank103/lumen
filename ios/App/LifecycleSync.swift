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
/// 4. No choosing: without a store on screen, more than one recent offer from that app means no accept.
/// 5. A passed offer stays passed: once the app is back to waiting for offers, or shows a newer offer, an older one is
///    accepted only through its store on a pickup screen.
/// 6. Another app's order in progress: a screen "for" an app with no order is likely a misread — no store, no accept.
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
        case "at_store":
            acceptFromPickupScreen(p, store: signal.store, now, otherAppBusy: otherAppBusy)
            step(.arrivedStore, p, now, inferred: false)
        case "heading_to_customer":
            if !hasOpenOrder(p) { promptMissedOrder(p, now, otherAppBusy: otherAppBusy); return }
            fillPickup(p, now)
        case "at_customer":
            if !hasOpenOrder(p) { promptMissedOrder(p, now, otherAppBusy: otherAppBusy); return }
            fillPickup(p, now)
            step(.arrivedDropoff, p, now, inferred: false)
        case "delivered":
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
            if let offer = candidates(platform, now, within: Self.storeMatchWindow).last(where: { Self.storeCodes($0).contains(store) }) {
                accept(offer, now)
            }
            return
        }
        // No store on screen: rules 1, 4, 5, 6 — a fresh accept of the only recent offer, never a stack or a guess.
        guard !hasOpenOrder(platform), !otherAppBusy, pending(.arrivedStore, platform) == nil else { return }
        let recent = candidates(platform, now, within: Self.offerLifetime)
        guard recent.count == 1, let offer = recent.first, isNewestOffer(offer) else { return }
        accept(offer, now)
    }

    /// A full reading, not a partial "Check offer" read of the same card (those appear right after the real one).
    private static func isFullRead(_ offer: LiveOffer) -> Bool { offer.outboundMilliMiles != nil }

    /// Offers from `platform` that could still be accepted: recent, not taken, shown after the app last waited for offers.
    private func candidates(_ platform: String, _ now: Date, within window: TimeInterval) -> [LiveOffer] {
        (model?.offers ?? []).filter { offer in
            offer.platform == platform && Self.isFullRead(offer) && now.timeIntervalSince(offer.seenAt) < window
                && TripStore.shared.trip(for: offer.offerId ?? offer.id) == nil && !DemoData.isDemo(offer.offerId)
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

    /// Leaving the store(s) before heading to the customer; an arrival that wasn't seen is filled in too.
    private func fillPickup(_ platform: String, _ now: Date) {
        for _ in 0..<6 {
            if step(.leftStore, platform, now, inferred: true) { continue }
            if step(.arrivedStore, platform, now, inferred: true) { continue }
            break
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
