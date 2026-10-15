import UserNotifications

/// Buttons on Lumen's notifications (user, Oct 14): "I accepted" on offers, and the next trip step on the trip
/// notification, so steps can be ticked from the lock screen without switching apps. Categories are per app, so the
/// app and the capture extension both register this same full set (each call replaces the whole set).
enum NotificationActions {
    static let offerCategory = "offer"
    static let accept = "offer.accept"
    static let next = "trip.next"
    static let undo = "trip.undo"
    /// The trip notification's category for each step kind (its button title names the step).
    static let stepTitles: [String: String] = [
        "arrivedStore": "Arrived at store", "leftStore": "Left store",
        "arrivedDropoff": "Arrived at drop-off", "delivered": "Delivered"
    ]
    static func tripCategory(_ kind: String) -> String { "trip." + kind }

    static func register() {
        let accept = UNNotificationAction(identifier: Self.accept, title: "✓ I accepted", options: [])
        var categories: Set<UNNotificationCategory> = [UNNotificationCategory(identifier: offerCategory, actions: [accept], intentIdentifiers: [])]
        let undo = UNNotificationAction(identifier: Self.undo, title: "Undo last step", options: [.destructive])
        for (kind, title) in stepTitles {
            let next = UNNotificationAction(identifier: Self.next, title: title, options: [])
            categories.insert(UNNotificationCategory(identifier: tripCategory(kind), actions: [next, undo], intentIdentifiers: []))
        }
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
}
