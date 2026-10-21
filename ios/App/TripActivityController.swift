import ActivityKit
import UIKit

/// Keeps the shift's Live Activity (lock screen + Dynamic Island) in step (user, Oct 21: "I'd like 1, 2, and 3"):
/// 1. a new offer's verdict for its 45 s, 2. "Reader off" when screen reading stops unexpectedly, 3. the shift's
/// earnings, $/hr, and day goal between orders — and the trip while on one. It runs from the start of a shift (or a
/// trip) to its end. iOS only lets an app *start* a Live Activity while it's open; after that, updates work in the
/// background (__APP_NAME__ runs during a shift for its miles).
@MainActor
enum TripActivityController {
    /// The offer on Home right now (set by AppModel every refresh).
    static var offer: LiveOffer?
    private static let activityId = "lumen-shift"
    private static var lastState: TripActivityAttributes.ContentState?
    private static var lastPush = Date.distantPast
    private static var goals: GoalsStatus?
    private static var goalsAt = Date.distantPast

    /// Returns whether a Live Activity is showing (then the trip notification isn't needed).
    @discardableResult
    static func update(_ trip: Trip?) -> Bool { sync(trip, force: true, now: Date()) }

    /// Called every few seconds by the app's refresh: pushes only what changed (and the clock-based numbers once a minute).
    static func refresh(_ trip: Trip?, now: Date = Date()) {
        if sync(trip, force: false, now: now), trip != nil { UNUserNotificationCenterProxy.removeTripNotification() }
    }

    @discardableResult
    private static func sync(_ trip: Trip?, force: Bool, now: Date) -> Bool {
        guard !PreviewData.isActive, ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        let activities = Activity<TripActivityAttributes>.activities
        guard let state = state(trip, now: now) else {
            for activity in activities { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
            lastState = nil
            return false
        }
        if let current = activities.first {
            for other in activities.dropFirst() { Task { await other.end(nil, dismissalPolicy: .immediate) } }
            if force || state != lastState || now.timeIntervalSince(lastPush) >= 60 {
                lastState = state; lastPush = now
                let stale = state.mode == "offer" ? state.offerUntil : nil
                Task { await current.update(ActivityContent(state: state, staleDate: stale)) }
            }
            return true
        }
        guard UIApplication.shared.applicationState == .active else { return false }
        lastState = state; lastPush = now
        return (try? Activity.request(attributes: TripActivityAttributes(tripId: activityId),
                                      content: ActivityContent(state: state, staleDate: nil), pushType: nil)) != nil
    }

    private static func verdictKey(_ notice: String?) -> String {
        switch Verdict(notice: notice) {
        case .accept: return "accept"
        case .decline: return "decline"
        case .maybe: return "maybe"
        }
    }

    private static func state(_ trip: Trip?, now: Date) -> TripActivityAttributes.ContentState? {
        let shifts = ShiftStore.shared
        guard trip != nil || shifts.current != nil else { return nil }
        let next = trip?.actions.first
        var s = TripActivityAttributes.ContentState(
            mode: trip == nil ? "idle" : "trip",
            startedAt: trip?.startedAt ?? shifts.current?.startedAt ?? now,
            // Predicted $/hr for the first 10 minutes (the live pace means little that early), then the live pace.
            paceText: (trip.flatMap { $0.elapsed(now) < 600 ? $0.predictedHourlyCents : nil } ?? trip?.paceCents(now)).map { "$\($0 / 100)/hr" } ?? "—",
            payText: trip.map { (Double($0.payCents) / 100).formatted(.currency(code: "USD")) } ?? "",
            orderCount: trip?.orders.filter { $0.ended == nil }.count ?? 0,
            nextLabel: next?.label, nextActionId: next?.id)
        if shifts.current != nil, let m = shifts.metrics {
            s.earningsText = ShiftFormat.money(m.earningsCents)
            s.hourlyText = ShiftFormat.rate(m.shiftHourlyCents, "hr")
            s.milesText = ShiftFormat.miles(m.miles.total)
        }
        // The day goal (else the shift goal), recomputed at most once a minute.
        if now.timeIntervalSince(goalsAt) >= 60 { goals = GoalsStatus.compute(now: now); goalsAt = now }
        if let day = goals?.daily {
            s.goalProgress = day.progress
            s.goalText = ShiftFormat.money(day.earningsCents) + " of " + ShiftFormat.money(day.goalCents) + " today"
        } else if let goal = shifts.metrics?.goal {
            s.goalProgress = goal.progress
            s.goalText = ShiftFormat.money(goal.remainingCents) + " to " + ShiftFormat.money(goal.goalCents)
        }
        if let offer, now.timeIntervalSince(offer.seenAt) < AppModel.offerHeroSeconds {
            let parts = (offer.notice ?? "").components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            s.mode = "offer"
            s.verdict = verdictKey(offer.notice)
            s.perMileText = parts.first { $0.hasSuffix("/mi") }
            s.perHourText = parts.first { $0.hasSuffix("/hr") }
            s.offerPayText = (Double(offer.payCents) / 100).formatted(.currency(code: "USD"))
            s.offerStore = offer.merchants?.first ?? offer.merchant
            s.offerUntil = offer.seenAt.addingTimeInterval(AppModel.offerHeroSeconds)
        }
        if shifts.current != nil, ReadingMonitor.shared.stoppedUnexpectedly { s.mode = "readerOff" }
        return s
    }
}

import UserNotifications

enum UNUserNotificationCenterProxy {
    static func removeTripNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [TripNotifier.identifier])
    }
}
