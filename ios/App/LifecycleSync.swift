import Foundation

/// Turns order states read off the delivery apps' screens (LifecycleSignal from the offer reader) into trip steps —
/// the end of manual ticking (user's labeled screenshots, Oct 15). Works with the GPS detector: whichever sees a step
/// first records it; the other finds nothing left to do. Off when "Tick trip steps automatically" is off.
/// - A pickup screen (heading to / at the store) for an app with no order waiting for pickup is positive evidence of
///   acceptance: the latest offer from that app (last 10 minutes, not already taken) is ticked as accepted.
/// - A screen past a step that wasn't seen (e.g. "heading to the customer" without "left the store") fills that step
///   in at low confidence, so its timing isn't used for learning but the trip keeps moving.
@MainActor
final class LifecycleSync {
    static let shared = LifecycleSync()
    weak var model: AppModel?
    private var lastState: [String: String] = [:]
    /// When each app was last seen waiting for offers: an offer shown before that was passed on, never accepted later.
    private var lastAvailable: [String: Date] = [:]

    func received(_ signal: LifecycleSignal, at now: Date = Date()) {
        let previous = lastState[signal.platform]
        lastState[signal.platform] = signal.state
        if signal.state == "available" { lastAvailable[signal.platform] = now; pendingAccept[signal.platform] = nil }
        guard AutoSteps.isEnabled else { return }
        let p = signal.platform
        switch signal.state {
        case "heading_to_store":
            if step(.leftStore, p, now, inferred: false) { return }   // Off to the next store of a multi-store order.
            if pending(.arrivedStore, p) == nil { acceptLatestOffer(p, now, within: 900) }
        case "navigating":
            // The app's own turn-by-turn only runs during an order: nothing open for this app means the accept was missed.
            if !hasOpenOrder(p) { acceptLatestOffer(p, now, within: 900) }
        case "at_store":
            // At the store with nothing pending: the accept wasn't seen (e.g. the driver went straight to their own maps);
            // the drive there can take a while, so look back 30 minutes.
            if pending(.arrivedStore, p) == nil && pending(.leftStore, p) == nil { acceptLatestOffer(p, now, within: 1800) }
            step(.arrivedStore, p, now, inferred: false)
        case "heading_to_customer":
            // Cross-check (Oct 17): delivering proves an accept even if every earlier screen was missed.
            if !hasOpenOrder(p) { acceptLatestOffer(p, now, within: 3600) }
            fillPickup(p, now)
        case "at_customer":
            if !hasOpenOrder(p) { acceptLatestOffer(p, now, within: 3600) }
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

    /// A late accept waiting for a second, different order screen from the same app (user, Oct 18: a chat on the phone
    /// quoting the apps' buttons produced one false step, and a declined offer was marked accepted 10 minutes later).
    private var pendingAccept: [String: (offerId: String, states: Set<String>, firstState: String, firstAt: Date)] = [:]

    private func acceptLatestOffer(_ platform: String, _ now: Date, within window: TimeInterval = 600) {
        let state = lastState[platform] ?? ""
        guard let offer = model?.offers.last(where: { offer in
            offer.platform == platform && now.timeIntervalSince(offer.seenAt) < window
                && TripStore.shared.trip(for: offer.offerId ?? offer.id) == nil && !DemoData.isDemo(offer.offerId)
                // The app went back to waiting for offers after this one: it was declined or expired.
                && offer.seenAt > (lastAvailable[platform] ?? .distantPast)
        }) else { pendingAccept[platform] = nil; return }
        let offerId = offer.offerId ?? offer.id
        // The usual case — the pickup screen within 10 minutes of the offer — accepts at once. Anything later needs two
        // different order screens from that app (e.g. at the store, then heading to the customer).
        if !(state == "heading_to_store" && now.timeIntervalSince(offer.seenAt) <= 600) {
            var pending = pendingAccept[platform]
            if pending?.offerId != offerId || now.timeIntervalSince(pending?.firstAt ?? now) > window { pending = nil }
            if pending == nil {
                pendingAccept[platform] = (offerId, [state], state, now)
                return
            }
            guard let first = pending, !first.states.contains(state) else { return }
            pendingAccept[platform] = nil
            accept(offer, now)
            // The first screen's step happened then, not now.
            if first.firstState == "at_store" { step(.arrivedStore, platform, first.firstAt, inferred: false) }
            return
        }
        pendingAccept[platform] = nil
        accept(offer, now)
    }

    private func accept(_ offer: LiveOffer, _ now: Date) {
        // Found late (minutes after the offer): it was accepted right after it was shown, not now.
        let late = now.timeIntervalSince(offer.seenAt) > 120
        TripStore.shared.accept(TripOfferInfo(offer), at: late ? offer.seenAt.addingTimeInterval(20) : now,
                                source: late ? "screen_late" : "screen")
    }
}
