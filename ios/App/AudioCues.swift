import AVFoundation
import UIKit

/// Spoken cues when an order is marked accepted or delivered (user, Oct 15) — by a tap, the GPS, or the delivery app's
/// screen — so the driver knows without looking. Only those two phrases, nothing else (user, Oct 15: no store names,
/// minutes, or pay). Like navigation prompts: other audio ducks briefly, it plays with the
/// ringer on silent, and works while Lumen runs in the background (audio background mode). Account › Speak… turns it off.
@MainActor
final class AudioCues: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = AudioCues()
    static let enabledKey = "audioCues"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func accepted() { speak("Order accepted"); haptic() }

    func delivered() { speak("Order delivered"); haptic() }

    /// A success tap with each cue (polish pass), felt even when the voice is off.
    private func haptic() { UINotificationFeedbackGenerator().notificationOccurred(.success) }

    func test() { speak("Lumen voice cues are on") }

    private func speak(_ text: String) {
        guard Self.isEnabled, !PreviewData.isActive else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            // Let music come back up once nothing else is queued.
            if !synthesizer.isSpeaking { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        }
    }
}
