import Foundation
import Photos
import UserNotifications

/// "Save offer screens to Photos" (user, Oct 25: "capture/screenshot the offer screens… especially from Grubhub").
/// While on, the screen reader keeps each offer screen it reads (720 px wide) on that offer's verdict notification
/// (TrainingAttachment); when the app collects the offers it saves the screens to Photos, to be marked in the PC's pin
/// marking tool. The reader never writes to Photos itself (that killed it, Oct 25). The switch reaches the reader
/// through the bridge and as a signal — also each time the reader starts. Photos asks for "add photos" permission first.
enum TrainingCapture {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "trainingCapture") }
    /// Screens saved to Photos so far (for the switch's footer).
    static var savedCount: Int { UserDefaults.standard.integer(forKey: "trainingSavedCount") }
    /// Notifications whose screen is already in Photos (the last 300), so a screen is saved once.
    private static let doneKey = "trainingSavedNotifications"
    private static var saving = false

    /// Save the screens riding on delivered offer notifications (the app collects offers at launch, on return, and
    /// while open). A notification cleared before __APP_NAME__ was opened takes its screen with it.
    static func collect(from delivered: [UNNotification]) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard !saving, status == .authorized || status == .limited else { return }
        let done = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
        var screens: [(id: String, data: Data, name: String)] = []
        for note in delivered where !done.contains(note.request.identifier) {
            guard let attachment = note.request.content.attachments.first(where: { $0.identifier == TrainingAttachment.identifier })
            else { continue }
            let url = attachment.url
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = note.request.content.userInfo[TrainingAttachment.nameKey] as? String ?? "__APP_NAME__ training.jpg"
            screens.append((note.request.identifier, data, name))
        }
        guard !screens.isEmpty else { return }
        saving = true
        PHPhotoLibrary.shared().performChanges({
            for screen in screens {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = screen.name
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: screen.data, options: options)
            }
        }, completionHandler: { ok, _ in
            DispatchQueue.main.async {
                saving = false
                guard ok else { return }
                // The silent notifications that carried them are done: out of Notification Center (and their images out
                // of iOS's attachment store).
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: screens.map(\.id).filter { $0.hasPrefix(TrainingAttachment.requestPrefix) })
                let ids = (UserDefaults.standard.stringArray(forKey: doneKey) ?? []) + screens.map(\.id)
                UserDefaults.standard.set(Array(ids.suffix(300)), forKey: doneKey)
                UserDefaults.standard.set(savedCount + screens.count, forKey: "trainingSavedCount")
            }
        })
    }

    static func set(_ on: Bool) {
        if on {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in republish() }
        } else {
            republish()
        }
    }

    /// Hand the switch to the reader again (at launch, every 5 minutes, and when the reader starts).
    static func republish() {
        Bridge.publish("training-capture", Data((isOn ? "on" : "off").utf8))
        (isOn ? Signal.trainingOn : Signal.trainingOff).post()
    }

    /// For the switch's footer: whether Photos will take the screens.
    static var permission: String {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited: return "Photos: allowed"
        case .denied, .restricted: return "Photos: not allowed — turn on in Settings › __APP_NAME__ › Photos"
        default: return "Photos: will ask"
        }
    }
}
