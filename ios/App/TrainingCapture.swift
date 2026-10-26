import Foundation
import Photos

/// "Save offer screens to Photos" (user, Oct 25: "capture/screenshot the offer screens… especially from Grubhub").
/// While on, the screen reader keeps each offer screen it reads (720 px wide) and hands it to the app (TrainingHandoff);
/// the app saves them to Photos when it's in front, to be marked in the PC's pin marking tool. The reader never writes to
/// Photos itself (that killed it, Oct 25). The switch reaches the reader through the bridge and, in case the bridge
/// doesn't work on this install, as a signal too. Photos asks for "add photos" permission the first time.
enum TrainingCapture {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "trainingCapture") }
    /// Screens saved to Photos so far (for the switch's footer).
    static var savedCount: Int { UserDefaults.standard.integer(forKey: "trainingSavedCount") }

    /// Move the screens the reader handed over into Photos (app in front: at launch, on return, every 5 minutes).
    private static var draining = false

    static func drain() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard !draining, status == .authorized || status == .limited else { return }
        let (screens, done) = TrainingHandoff.take()
        guard !screens.isEmpty else { return }
        draining = true
        PHPhotoLibrary.shared().performChanges({
            for (data, name) in screens {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = name
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
            }
        }, completionHandler: { ok, _ in
            DispatchQueue.main.async {
                draining = false
                guard ok else { return }
                done()
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

    /// Hand the switch to the reader again (at launch and every 5 minutes, like the other settings).
    static func republish() {
        Bridge.publish("training-capture", Data((isOn ? "on" : "off").utf8))
        (isOn ? Signal.trainingOn : Signal.trainingOff).post()
    }

    /// For the switch's footer: whether Photos will take the reader's images.
    static var permission: String {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited: return "Photos: allowed"
        case .denied, .restricted: return "Photos: not allowed — turn on in Settings › __APP_NAME__ › Photos"
        default: return "Photos: will ask"
        }
    }
}
