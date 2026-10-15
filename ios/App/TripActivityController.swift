import ActivityKit
import UIKit

/// Keeps the trip's Live Activity (lock screen + Dynamic Island) in step with the trip. iOS only lets an app *start* a
/// Live Activity while it's open, so a trip accepted from a notification shows the trip notification until Lumen is
/// next opened; after that, updates work in the background.
@MainActor
enum TripActivityController {
    private static var lastRefresh = Date.distantPast

    /// Returns whether a Live Activity is showing this trip (then the trip notification isn't needed).
    @discardableResult
    static func update(_ trip: Trip?) -> Bool {
        guard !PreviewData.isActive, ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        let activities = Activity<TripActivityAttributes>.activities
        guard let trip else {
            for activity in activities { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
            return false
        }
        let next = trip.actions.first
        let state = TripActivityAttributes.ContentState(
            startedAt: trip.startedAt,
            paceText: trip.paceCents(Date()).map { "$\($0 / 100)/hr" } ?? "—",
            payText: (Double(trip.payCents) / 100).formatted(.currency(code: "USD")),
            orderCount: trip.orders.filter { $0.ended == nil }.count,
            nextLabel: next?.label, nextActionId: next?.id)
        for other in activities where other.attributes.tripId != trip.id { Task { await other.end(nil, dismissalPolicy: .immediate) } }
        if let current = activities.first(where: { $0.attributes.tripId == trip.id }) {
            Task { await current.update(ActivityContent(state: state, staleDate: nil)) }
            return true
        }
        guard UIApplication.shared.applicationState == .active else { return false }
        return (try? Activity.request(attributes: TripActivityAttributes(tripId: trip.id),
                                      content: ActivityContent(state: state, staleDate: nil), pushType: nil)) != nil
    }

    /// Called every few seconds: refresh the pace once a minute, and start the Live Activity once the app is open.
    static func refresh(_ trip: Trip?, now: Date = Date()) {
        let missing = trip != nil && !Activity<TripActivityAttributes>.activities.contains { $0.attributes.tripId == trip?.id }
        guard missing || now.timeIntervalSince(lastRefresh) >= 60 else { return }
        lastRefresh = now
        if update(trip) && missing { UNUserNotificationCenterProxy.removeTripNotification() }
    }
}

import UserNotifications

enum UNUserNotificationCenterProxy {
    static func removeTripNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [TripNotifier.identifier])
    }
}
