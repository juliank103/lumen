import SwiftUI
import UserNotifications
import CoreLocation

/// Alerts when offer reading stops by itself during a shift (review item: silent failure). iOS can end the screen
/// broadcast (memory, a call) without the extension saying so; the app, running for the shift's miles, sees the screen
/// is no longer captured. A deliberate stop sends the extension's "finished" signal first, which suppresses the alert.
@MainActor
final class ReadingMonitor {
    static let shared = ReadingMonitor()
    static let notificationId = "reading-stopped"

    private var seenCapturing = false
    private var outageSince: Date?
    private var alerted = false
    private var finishedAt: Date?

    func readingFinished(at now: Date = Date()) { finishedAt = now }

    /// Screen reading stopped without being stopped (20 s+): the Dynamic Island shows "Reader off".
    var stoppedUnexpectedly: Bool { alerted }

    func check(now: Date = Date()) {
        if UIScreen.main.isCaptured {
            if alerted { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationId]) }
            seenCapturing = true; outageSince = nil; alerted = false
            return
        }
        guard seenCapturing else { return } // Reading never ran this session (manual trips only): nothing to warn about.
        let since = outageSince ?? now
        outageSince = since
        if let finishedAt, finishedAt >= since.addingTimeInterval(-15) { return } // Stopped on purpose.
        guard !alerted, now.timeIntervalSince(since) >= 20 else { return }
        alerted = true
        let content = UNMutableNotificationContent()
        content.title = "__APP_NAME__ stopped reading offers"
        content.body = "Offers won't get a verdict. Open __APP_NAME__ and tap the status at the top to start again."
        content.threadIdentifier = "status"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationId, content: content, trigger: nil))
    }
}

/// Settings __APP_NAME__ depends on, checked live (review item: setup health). Only problems are listed.
struct SetupIssue: Identifiable {
    let id: String
    let title: String
    let detail: String
}

extension AppModel {
    var setupIssues: [SetupIssue] {
        var issues: [SetupIssue] = []
        if notificationStatus == "Off" || notificationStatus == "Not asked yet" {
            issues.append(SetupIssue(id: "notifications", title: "Notifications are off", detail: "Offer verdicts arrive as notifications."))
        } else if bannerStatus == "Off" {
            issues.append(SetupIssue(id: "banners", title: "Banners are off", detail: "Verdicts only land in Notification Center."))
        }
        if summaryStatus.hasPrefix("On") {
            issues.append(SetupIssue(id: "summary", title: "Scheduled Summary holds offers", detail: "Turn it off for __APP_NAME__ so verdicts arrive at once."))
        }
        if LocationAccess.manager.authorizationStatus != .authorizedAlways {
            issues.append(SetupIssue(id: "location", title: "Location isn't set to Always", detail: "Needed for shift miles and automatic arrivals."))
        }
        if ShiftStore.shared.current?.pausedAt == nil, ShiftStore.shared.current != nil, !screenCaptured {
            issues.append(SetupIssue(id: "reading", title: "Offer reading is off", detail: "Tap the status at the top to start it."))
        }
        return issues
    }
}

/// Dash card shown only when something needs attention.
struct SetupHealthCard: View {
    let issues: [SetupIssue]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(issues.count == 1 ? "1 setting needs attention" : "\(issues.count) settings need attention",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(issue.title).font(.subheadline.weight(.semibold))
                        Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if issues.contains(where: { $0.id != "reading" }) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .dasherCard()
        }
    }
}
