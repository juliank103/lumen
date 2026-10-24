import CoreImage
import Foundation
import Vision

/// Reader 2, piece 1 (Oct 24 plan): Apple's structured document reader (iOS 26+) on the offer card. Unlike raw text
/// lines, it tags what each piece is — money ("$14.75" → 14.75), measurements ("9.4 mi" → 9.4 miles, "32 min" →
/// 32 minutes) — so the numbers don't depend on hand-written patterns. For now it runs alongside the current reader
/// (once per offer, after the verdict, only when "Reader 2 trial" is on in Account), and its answer is saved with the
/// offer to compare.
enum DocReader {
    struct Result: Codable {
        var payCents: [Int] = []
        var milliMiles: [Int] = []
        var minutes: [Int] = []
        var ms = 0
    }

    /// On when the app's Account switch handed "on" over the bridge.
    static var trialOn: Bool { Bridge.read("reader2-trial").map { String(decoding: $0, as: UTF8.self) == "on" } ?? false }

    static func read(_ card: CIImage) async -> Result? {
        guard #available(iOS 26.0, *) else { return nil }
        let start = Date()
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = false
        request.barcodeDetectionOptions.enabled = false
        guard let documents = try? await request.perform(on: card, orientation: nil), let document = documents.first else { return nil }
        var result = Result()
        let containers = [document.document.text] + document.document.paragraphs
        var seen = Set<String>()
        for text in containers {
            for found in text.detectedData {
                switch found.match.details {
                case .moneyAmount(let money):
                    let cents = NSDecimalNumber(decimal: money.amount * 100).intValue
                    if seen.insert("$\(cents)").inserted { result.payCents.append(cents) }
                case .measurement(let m):
                    if m.possibleDimensions.contains(where: { $0 is UnitLength }) {
                        let mm = Int((m.measurement(in: UnitLength.miles).value * 1000).rounded())
                        if seen.insert("mi\(mm)").inserted { result.milliMiles.append(mm) }
                    } else if m.possibleDimensions.contains(where: { $0 is UnitDuration }) {
                        let minutes = Int(m.measurement(in: UnitDuration.minutes).value.rounded())
                        if seen.insert("min\(minutes)").inserted { result.minutes.append(minutes) }
                    }
                default:
                    break
                }
            }
        }
        result.ms = Int(Date().timeIntervalSince(start) * 1000)
        return result
    }
}

/// Holds Reader 2's answer until the offer is saved (written on a Vision task, read on `processing`).
final class DocReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DocReader.Result?
    var value: DocReader.Result? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ result: DocReader.Result?) { lock.lock(); stored = result; lock.unlock() }
}
