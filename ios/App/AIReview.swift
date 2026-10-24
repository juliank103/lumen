import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The AI teacher (Oct 24 plan: "make the reader better"): with the app open, Apple's on-device model re-reads the card
/// text of every saved offer and __APP_NAME__ compares its answer with what the reader got. Each disagreement is a likely
/// misread — by the reader or the model — and the list goes into the export, where it drives reader fixes and becomes
/// the answer key Reader 2 is tested against. Every number the model gives must appear in the card text, or it's ignored.
/// Runs on the phone only, in the app (not throttled like the screen reader); the card text is the reader's own saved
/// text (no map, no cross streets).
struct AIReviewItem: Codable, Equatable {
    let offerId: String
    let platform: String
    let reviewedAt: Date
    /// The model's reading, as numbers (nil = it found none, or its value wasn't in the card text).
    var payCents: Int?
    var milliMiles: Int?
    var minutes: Int?
    var store: String?
    /// "agree", or the fields that differ ("pay", "miles", "minutes"), or "error: …".
    var outcome: String
}

@MainActor
final class AIReviewStore: ObservableObject {
    static let shared = AIReviewStore()
    @Published private(set) var items: [String: AIReviewItem] = [:]
    @Published private(set) var running = false
    @Published private(set) var progress = (done: 0, total: 0)
    @Published private(set) var lastError: String?
    private var stopRequested = false

    private var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("ai-review.json")
    }

    private init() {
        if let url, let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([AIReviewItem].self, from: data) {
            items = Dictionary(list.map { ($0.offerId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(Array(items.values).sorted { $0.reviewedAt < $1.reviewedAt }),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(Array(items.values)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func stop() { stopRequested = true }

    /// Reviews offers with saved card text that haven't been reviewed yet, newest first.
    func run(_ offers: [LiveOffer]) {
        guard !running else { return }
        let todo = offers.filter { ($0.cardLines?.isEmpty == false) && items[$0.offerId ?? $0.id] == nil && !DemoData.isDemo($0.offerId) }
            .sorted { $0.seenAt > $1.seenAt }
        guard !todo.isEmpty else { return }
        running = true; stopRequested = false; lastError = nil
        progress = (0, todo.count)
        Task {
            for offer in todo {
                if stopRequested { break }
                let item = await Self.review(offer)
                items[item.offerId] = item
                progress.done += 1
                if item.outcome.hasPrefix("error") {
                    lastError = item.outcome
                    // Throttled or unavailable: stop rather than burn through the list.
                    if item.outcome.lowercased().contains("rate") || item.outcome.contains("unavailable") { break }
                }
                if progress.done % 10 == 0 { save() }
            }
            save()
            running = false
        }
    }

    /// The card's text in reading order (top to bottom, left to right).
    static func cardText(_ offer: LiveOffer) -> String {
        let lines = (offer.cardLines ?? []).compactMap { raw -> (Double, Double, String)? in
            let parts = raw.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, let y = Double(parts[0]), let x = Double(parts[1]) else { return nil }
            return (y, x, String(parts[4]))
        }
        return lines.sorted { abs($0.0 - $1.0) < 0.01 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.2).joined(separator: "\n")
    }

    static func review(_ offer: LiveOffer) async -> AIReviewItem {
        let id = offer.offerId ?? offer.id
        var item = AIReviewItem(offerId: id, platform: offer.platform, reviewedAt: Date(), outcome: "error: unavailable")
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), AIProbe.availability() == "available" else { return item }
        let text = cardText(offer)
        do {
            let session = LanguageModelSession(instructions: """
            You read delivery offer cards from DoorDash, Uber Eats and Grubhub. Copy values exactly as they appear in the \
            text. Pay is the main dollar amount the driver earns. Miles is the trip distance. Minutes is the total trip time \
            if shown (not a pickup time). Leave a field empty if the card doesn't show it.
            """)
            let read = try await session.respond(to: "App: \(Theme.appName(offer.platform))\nCard text:\n" + text,
                                                 generating: ReviewOffer.self).content
            // Grounding: a value counts only if its text is on the card.
            let found = { (value: String) -> String? in
                let v = value.trimmingCharacters(in: .whitespaces)
                return !v.isEmpty && text.contains(v) ? v : nil
            }
            item.payCents = found(read.pay).flatMap { Double($0.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) }
                .map { Int(($0 * 100).rounded()) }
            item.milliMiles = found(read.miles).flatMap { Double($0) }.map { Int(($0 * 1000).rounded()) }
            item.minutes = found(read.minutes).flatMap { Int($0) }
            item.store = found(read.store)
            var differ: [String] = []
            if let p = item.payCents, p != offer.payCents { differ.append("pay") }
            if let m = item.milliMiles, m != offer.outboundMilliMiles { differ.append("miles") }
            if item.minutes != offer.appMinutes && !(item.minutes == nil && offer.appMinutes == nil) { differ.append("minutes") }
            if item.payCents == nil { differ.append("pay not found") }
            item.outcome = differ.isEmpty ? "agree" : differ.joined(separator: ",")
        } catch {
            item.outcome = "error: " + String(describing: error).prefix(120)
        }
        #endif
        return item
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct ReviewOffer {
    @Guide(description: "Main pay amount exactly as written, e.g. $14.75 (empty if none)")
    var pay: String
    @Guide(description: "Trip miles number exactly as written, e.g. 9.4 (empty if none)")
    var miles: String
    @Guide(description: "Total trip minutes number exactly as written, e.g. 32 (empty if not shown)")
    var minutes: String
    @Guide(description: "First restaurant name exactly as written (empty if none)")
    var store: String
}
#endif

/// Diagnostics → AI review of saved offers.
struct AIReviewSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = AIReviewStore.shared

    private var counts: (agree: Int, differ: Int, errors: Int) {
        store.items.values.reduce(into: (0, 0, 0)) { c, i in
            if i.outcome == "agree" { c.0 += 1 } else if i.outcome.hasPrefix("error") { c.2 += 1 } else { c.1 += 1 }
        }
    }

    var body: some View {
        Section {
            let c = counts
            HStack { Text("Reviewed"); Spacer(); Text("\(store.items.count)").foregroundStyle(.secondary) }
            HStack { Text("AI agrees with the reader"); Spacer(); Text("\(c.agree)").foregroundStyle(.secondary) }
            HStack { Text("Disagrees (likely misreads)"); Spacer(); Text("\(c.differ)").foregroundStyle(.secondary) }
            if c.errors > 0 { HStack { Text("Couldn't review"); Spacer(); Text("\(c.errors)").foregroundStyle(.secondary) } }
            if store.running {
                HStack {
                    ProgressView(value: Double(store.progress.done), total: Double(max(1, store.progress.total)))
                    Button("Stop") { store.stop() }
                }
                Text("Keep __APP_NAME__ open. About 2 seconds per offer.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Button("Review saved offers") { store.run(model.offers) }
            }
            if let error = store.lastError { Text(error).font(.caption.monospaced()).foregroundStyle(.secondary) }
        } header: {
            Text("AI review of saved offers")
        } footer: {
            Text("Apple Intelligence re-reads each saved offer card on this iPhone and flags where it disagrees with the reader. The results go into your export.")
        }
    }
}
