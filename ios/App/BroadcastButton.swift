import SwiftUI
import ReplayKit

/// Full-width Dasher-style pill that opens the system broadcast sheet. Only the system picker can start a broadcast;
/// laying it invisibly over the pill did not receive taps on the user's phone (build 19), so the pill now presses
/// the picker's own button directly. The picker stays in the view hierarchy (1×1, transparent, hosted once at the root
/// of ContentView) so it can present.
struct BroadcastButton: View {
    let running: Bool

    var body: some View {
        Button { BroadcastLauncher.shared.open() } label: {
            Text(running ? "Stop reading offers" : "Start reading offers")
                .font(.headline.weight(.bold))
                .foregroundStyle(running ? Theme.purple : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(running ? Theme.card : Theme.purple, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Holds the one system picker and presses its button on demand.
final class BroadcastLauncher {
    static let shared = BroadcastLauncher()

    let picker: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = BroadcastLauncher.extensionIdentifier
        picker.showsMicrophoneButton = false
        return picker
    }()

    /// The installed reader's real bundle ID. AltStore re-signs with its own IDs (team suffix), so the ID written at
    /// build time doesn't match and iOS showed every broadcast app (Photos ticked, a list that wouldn't scroll — user,
    /// Oct 16). Read it from the bundled extension instead; the build-time value is the fallback.
    static var extensionIdentifier: String? {
        if let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("CaptureProbe.appex"),
           let id = Bundle(url: url)?.bundleIdentifier { return id }
        return Bundle.main.object(forInfoDictionaryKey: "CaptureExtensionIdentifier") as? String
    }

    func open() {
        guard let button = Self.firstButton(in: picker) else { return }
        button.sendActions(for: .allTouchEvents)
    }

    private static func firstButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for child in view.subviews { if let found = firstButton(in: child) { return found } }
        return nil
    }
}

struct PickerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.clipsToBounds = true  // Keep the 44-pt system button from showing as a faint ring.
        container.isUserInteractionEnabled = false
        let picker = BroadcastLauncher.shared.picker
        picker.removeFromSuperview()
        container.addSubview(picker)
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        let picker = BroadcastLauncher.shared.picker
        if picker.superview !== uiView { picker.removeFromSuperview(); uiView.addSubview(picker) }
    }
}
