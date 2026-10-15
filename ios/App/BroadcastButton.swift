import SwiftUI
import ReplayKit

/// Full-width Dasher-style pill that opens the system broadcast sheet. Only the system picker can start a broadcast;
/// laying it invisibly over the pill did not receive taps on the user's phone (build 19), so the pill now presses
/// the picker's own button directly. The picker stays in the view hierarchy (1×1, transparent) so it can present.
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
        .background(PickerHost().frame(width: 1, height: 1).opacity(0.01))
    }
}

/// Holds the one system picker and presses its button on demand.
final class BroadcastLauncher {
    static let shared = BroadcastLauncher()

    let picker: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = Bundle.main.object(forInfoDictionaryKey: "CaptureExtensionIdentifier") as? String
        picker.showsMicrophoneButton = false
        return picker
    }()

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
