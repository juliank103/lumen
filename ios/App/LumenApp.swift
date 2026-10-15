import SwiftUI
import UserNotifications

// Offer notifications also show as banners while this app is open (iOS hides them in the foreground by default);
// the quiet trip notification stays in the list. Notification buttons ("I accepted", the next trip step, Undo) are
// handled here, also when iOS launches the app in the background just for the tap.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier == TripNotifier.identifier ? [.list] : [.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            TripStore.shared.handle(actionIdentifier: action, userInfo: userInfo)
            completionHandler()
        }
    }
}

@main
struct LumenApp: App {
    private let presenter = NotificationPresenter()
    init() {
        UNUserNotificationCenter.current().delegate = presenter
        NotificationActions.register()
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
