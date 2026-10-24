import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence test (Oct 24, 2026 plan, step 1): does the on-device model work on this phone, how fast does it
/// read an offer card, and — the deciding question — can the screen reader call it while a delivery app is in front, or
/// is it blocked or throttled there? The screen reader writes its result to the bridge; Diagnostics shows both.
/// Invented sample text only; nothing from real offers goes into these test prompts.
enum AIProbe {
    struct Result: Codable, Equatable {
        var at: Date
        /// "available", or why not ("device not eligible", "Apple Intelligence off", "model not ready", "not in this SDK").
        var availability: String
        /// Calls tried / answered, the error of the first failure, and seconds per answered call.
        var calls = 0
        var answered = 0
        var firstError: String?
        var seconds: [Double] = []
        /// The test card read by the model (app test only), and whether every number was found in the card text.
        var extracted: String?
        var grounded: Bool?
    }

    static let sampleCard = """
    $14.75
    Guaranteed (incl. tips)
    32 min (9.4 mi) total
    Sample Diner
    Pickup · 2 orders
    Deliver to Springfield
    """

    static func availability() -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "available"
            case .unavailable(let reason): return "unavailable: " + String(describing: reason)
            @unknown default: return "unknown"
            }
        }
        return "needs iOS 26"
        #else
        return "not in this build's SDK"
        #endif
    }

    /// `calls` short requests, `spacing` seconds apart (the screen reader's burst test for throttling).
    static func run(calls: Int, spacing: TimeInterval, readCard: Bool) async -> Result {
        var result = Result(at: Date(), availability: availability())
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), result.availability == "available" else { return result }
        for i in 0..<calls {
            if i > 0 { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
            result.calls += 1
            let start = Date()
            do {
                let session = LanguageModelSession(instructions: "You read delivery offer cards. Copy values exactly as written.")
                if readCard && i == 0 {
                    let card = try await session.respond(to: "Offer card text:\n" + sampleCard, generating: ProbeOffer.self).content
                    result.extracted = "pay \(card.pay) · miles \(card.miles) · minutes \(card.minutes) · store \(card.store)"
                    // Grounding: every value must appear in the card text.
                    result.grounded = [card.pay, card.miles, card.minutes, card.store].allSatisfy { !$0.isEmpty && sampleCard.contains($0) }
                } else {
                    _ = try await session.respond(to: "Reply with the single word: ready")
                }
                result.answered += 1
                result.seconds.append((Date().timeIntervalSince(start) * 100).rounded() / 100)
            } catch {
                if result.firstError == nil { result.firstError = String(describing: error).prefix(160).description }
            }
        }
        #endif
        return result
    }

    // Results travel through the bridge (screen reader → app).
    static func save(_ result: Result, key: String) {
        if let data = try? JSONEncoder().encode(result) { Bridge.publish(key, data) }
    }
    static func load(key: String) -> Result? {
        Bridge.read(key).flatMap { try? JSONDecoder().decode(Result.self, from: $0) }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct ProbeOffer {
    @Guide(description: "The pay amount exactly as written, e.g. $14.75")
    var pay: String
    @Guide(description: "The miles number exactly as written, e.g. 9.4")
    var miles: String
    @Guide(description: "The minutes number exactly as written, e.g. 32")
    var minutes: String
    @Guide(description: "The restaurant name exactly as written")
    var store: String
}
#endif
