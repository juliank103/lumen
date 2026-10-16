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

    func received(_ signal: LifecycleSignal, at now: Date = Date()) {
        let previous = lastState[signal.platform]
        lastState[signal.platform] = signal.state
        guard AutoSteps.isEnabled else { return }
        let p = signal.platform
        switch signal.state {
        case "heading_to_store":
            if step(.leftStore, p, now, inferred: false) { return }   // Off to the next store of a multi-store order.
            if pending(.arrivedStore, p) == nil { acceptLatestOffer(p, now) }
        case "at_store":
            // At the store with nothing pending: the accept wasn't seen (e.g. the driver went straight to their own maps);
            // the drive there can take a while, so look back 30 minutes.
            if pending(.arrivedStore, p) == nil && pending(.leftStore, p) == nil { acceptLatestOffer(p, now, within: 1800) }
            step(.arrivedStore, p, now, inferred: false)
        case "heading_to_customer":
            fillPickup(p, now)
        case "at_customer":
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

    private func acceptLatestOffer(_ platform: String, _ now: Date, within window: TimeInterval = 600) {
        guard let offer = model?.offers.last(where: { offer in
            offer.platform == platform && now.timeIntervalSince(offer.seenAt) < window
                && TripStore.shared.trip(for: offer.offerId ?? offer.id) == nil && !DemoData.isDemo(offer.offerId)
        }) else { return }
        TripStore.shared.accept(TripOfferInfo(offer), at: now, source: "screen")
    }
}
