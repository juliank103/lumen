import SwiftUI
import PhotosUI
import Vision
import JavaScriptCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Compare readers on real offer screenshots (Oct 24: "make the reader better or produce a better system than an OCR
/// reader"). For each screenshot the driver picks: today's reader (text recognition + rules, the same script the screen
/// reader runs), Apple Intelligence reading that text, Apple Intelligence reading the picture itself (plus what it sees
/// on the map), and Apple's structured document reader (Reader 2). Each answer with its time. On the phone only; the
/// screenshots aren't kept — only the numbers each reader got, for the export.
struct ReaderComparison: Codable, Identifiable, Equatable {
    struct Read: Codable, Equatable {
        var pay: String?
        var miles: String?
        var minutes: String?
        var store: String?
        var extra: String?
        var ms: Int
        var note: String?
    }
    var id = UUID()
    var app: String?
    var rules: Read?
    var aiText: Read?
    var aiPicture: Read?
    var documents: Read?
}

@MainActor
final class ReaderCompareStore: ObservableObject {
    static let shared = ReaderCompareStore()
    @Published private(set) var results: [ReaderComparison] = []
    @Published private(set) var running = false
    @Published private(set) var progress = (done: 0, total: 0)

    var json: String {
        (try? JSONEncoder().encode(results)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    func run(_ items: [PhotosPickerItem]) {
        guard !running, !items.isEmpty else { return }
        running = true
        progress = (0, items.count)
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data)?.cgImage {
                    results.insert(await Self.compare(image), at: 0)
                }
                progress.done += 1
            }
            running = false
        }
    }

    // MARK: Readers

    struct Line { let text: String; let x: Double; let y: Double; let w: Double; let h: Double }

    /// Text recognition like the screen reader: fast, no language correction, English, top-left coordinates.
    static func recognize(_ image: CGImage, top: Double) -> [Line] {
        let height = Double(image.height), cropTop = Int(height * top)
        guard let band = image.cropping(to: CGRect(x: 0, y: cropTop, width: image.width, height: image.height - cropTop)) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: band, options: [:]).perform([request])
        return (request.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first, c.confidence >= 0.3 else { return nil }
            let b = o.boundingBox
            return Line(text: c.string, x: Double(b.minX), y: top + Double(1 - b.maxY) * (1 - top), w: Double(b.width), h: Double(b.height) * (1 - top))
        }
    }

    private static let script: JSContext? = {
        guard let context = JSContext() else { return nil }
        for name in ["copilot", "screen-reader"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            context.evaluateScript(text)
        }
        return context
    }()

    static func compare(_ image: CGImage) async -> ReaderComparison {
        var out = ReaderComparison()
        // 1. Today's reader: the card band, the same rules.
        var start = Date()
        let lines = recognize(image, top: 0.4)
        let payload = lines.map { ["text": $0.text, "x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] as [String: Any] }
        if let context = script, let linesJSON = try? JSONSerialization.data(withJSONObject: payload),
           let summarize = context.objectForKeyedSubscript("ScreenReader")?.objectForKeyedSubscript("summarizeJSON"),
           let text = summarize.call(withArguments: [String(decoding: linesJSON, as: UTF8.self), RulesStore.current.settingsJSON, "{}"])?.toString(),
           let data = text.data(using: .utf8), let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            out.app = s["platform"] as? String
            out.rules = .init(pay: (s["payCents"] as? Int).map { String(format: "$%.2f", Double($0) / 100) },
                              miles: (s["outboundMilliMiles"] as? Int).map { String(format: "%.1f", Double($0) / 1000) },
                              minutes: (s["appMinutes"] as? Int).map(String.init),
                              store: (s["merchants"] as? [String])?.joined(separator: " + ") ?? s["merchant"] as? String,
                              ms: ms(start), note: nil)
        } else {
            out.rules = .init(ms: ms(start), note: "not an offer card to the rules")
        }
        let cardText = lines.sorted { abs($0.y - $1.y) < 0.01 ? $0.x < $1.x : $0.y < $1.y }.map(\.text).joined(separator: "\n")
        let allText = recognize(image, top: 0).map(\.text).joined(separator: "\n")

        // 2. Reader 2: Apple's structured document reader on the card.
        start = Date()
        if let doc = await DocReader.read(CIImage(cgImage: image.cropping(to: CGRect(x: 0, y: Int(Double(image.height) * 0.4),
                                                                                      width: image.width, height: image.height - Int(Double(image.height) * 0.4))) ?? image)) {
            out.documents = .init(pay: doc.payCents.map { String(format: "$%.2f", Double($0) / 100) }.joined(separator: ", "),
                                  miles: doc.milliMiles.map { String(format: "%.1f", Double($0) / 1000) }.joined(separator: ", "),
                                  minutes: doc.minutes.map(String.init).joined(separator: ", "), ms: ms(start))
        } else {
            out.documents = .init(ms: ms(start), note: "nothing found")
        }

        #if canImport(FoundationModels)
        if #available(iOS 27.0, *), AIProbe.availability() == "available" {
            // 3. Apple Intelligence on the card text.
            start = Date()
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let r = try await session.respond(to: "Card text:\n" + cardText, generating: ReviewOffer.self).content
                out.aiText = .init(pay: grounded(r.pay, in: allText), miles: grounded(r.miles, in: allText),
                                   minutes: grounded(r.minutes, in: allText), store: grounded(r.store, in: allText), ms: ms(start))
            } catch { out.aiText = .init(ms: ms(start), note: String(describing: error).prefix(100).description) }
            // 4. Apple Intelligence on the picture, with the map.
            start = Date()
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let small = downscaled(image, maxWidth: 800) ?? image
                let r = try await session.respond(generating: PictureOffer.self) {
                    "Read this delivery offer screen."
                    Attachment(small)
                }.content
                out.aiPicture = .init(pay: grounded(r.pay, in: allText), miles: grounded(r.miles, in: allText),
                                      minutes: grounded(r.minutes, in: allText), store: grounded(r.store, in: allText),
                                      extra: "map: \(r.mapState) · \(r.storePins) store pin(s), \(r.customerPins) customer pin(s)",
                                      ms: ms(start))
            } catch { out.aiPicture = .init(ms: ms(start), note: String(describing: error).prefix(100).description) }
        }
        #endif
        return out
    }

    static let instructions = """
    You read delivery offer screens from DoorDash, Uber Eats and Grubhub. Copy values exactly as they appear. Pay is the \
    main dollar amount the driver earns. Miles is the trip distance. Minutes is the total trip time if shown (not a pickup \
    time). Leave a field empty if it isn't shown.
    """

    /// A value counts only if it's on the screen (numbers the model makes up are dropped, shown as "✗ value").
    static func grounded(_ value: String, in text: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        return text.contains(v) ? v : "✗ " + v
    }

    static func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    static func downscaled(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct PictureOffer {
    @Guide(description: "Main pay amount exactly as written, e.g. $14.75 (empty if none)")
    var pay: String
    @Guide(description: "Trip miles number exactly as written, e.g. 9.4 (empty if none)")
    var miles: String
    @Guide(description: "Total trip minutes number exactly as written (empty if not shown)")
    var minutes: String
    @Guide(description: "First restaurant name exactly as written (empty if none)")
    var store: String
    @Guide(description: "The map: loaded, loading, or none")
    var mapState: String
    @Guide(description: "Number of restaurant/store pins on the map")
    var storePins: Int
    @Guide(description: "Number of customer/drop-off pins on the map")
    var customerPins: Int
}
#endif

/// Diagnostics → Compare readers on screenshots.
struct ReaderCompareSection: View {
    @ObservedObject private var store = ReaderCompareStore.shared
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        Section {
            PhotosPicker(selection: $picked, maxSelectionCount: 20, matching: .screenshots) {
                Label(store.running ? "Comparing \(store.progress.done) of \(store.progress.total)…" : "Choose offer screenshots",
                      systemImage: "photo.on.rectangle")
            }
            .disabled(store.running)
            .onChange(of: picked) { _, items in store.run(items); picked = [] }
            ForEach(store.results) { r in
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.app.map(Theme.appName) ?? "Screenshot").font(.subheadline.weight(.semibold))
                    row("Today's reader", r.rules)
                    row("AI, from text", r.aiText)
                    row("AI, from picture", r.aiPicture)
                    row("Structured reader", r.documents)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Compare readers on screenshots")
        } footer: {
            Text("Pick offer screenshots from Photos. Each reader's answer and time is shown; ✗ marks a number the AI made up. Screenshots aren't kept; results go into your export.")
        }
    }

    @ViewBuilder private func row(_ label: String, _ read: ReaderComparison.Read?) -> some View {
        if let read {
            VStack(alignment: .leading, spacing: 1) {
                Text(label + " · " + String(format: "%.1f s", Double(read.ms) / 1000)).font(.caption.weight(.semibold))
                let parts = [read.pay, read.miles.map { $0 + " mi" }, read.minutes.map { $0 + " min" }, read.store, read.extra, read.note]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                Text(parts.isEmpty ? "—" : parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
