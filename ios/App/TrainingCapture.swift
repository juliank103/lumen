import Foundation
import Photos

/// "Save offer screens to Photos" (user, Oct 25: "capture/screenshot the offer screens… especially from Grubhub").
/// While on, the screen reader saves each offer screen it reads to Photos at 720 px wide, to be marked in the PC's pin
/// marking tool and train the pin model. The switch reaches the reader through the bridge and, in case the bridge
/// doesn't work on this install, as a signal too. Photos asks for "add photos" permission the first time.
enum TrainingCapture {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "trainingCapture") }

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
