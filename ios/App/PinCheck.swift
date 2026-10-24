import SwiftUI
import PhotosUI
import Vision
import JavaScriptCore

/// Map pin check (Oct 24, step 1 of the map detector): on real offer screenshots, run the reader's own pin detector
/// (core/map-reader.js, the same 400 px map crop the screen reader uses) and draw what it found over the map. The
/// driver corrects the counts if they're wrong; the counts (no images, no places) go into the export as the first real
/// score of the detector, per app — and the failing cases show what a trained detector has to fix.
struct PinCheckItem: Identifiable {
    let id = UUID()
    let app: String
    let map: UIImage
    let pins: [(x: Double, y: Double, r: Double, kind: String)]
    let dot: (x: Double, y: Double)?
    let ms: Int
    var stores: Int
    var customers: Int
    var confirmed = false

    var detectedStores: Int { pins.filter { $0.kind == "store" }.count }
    var detectedCustomers: Int { pins.filter { $0.kind == "customer" }.count }
    var detectedUnknown: Int { pins.filter { $0.kind == "unknown" }.count }
}

struct PinCheckRecord: Codable {
    let app: String
    let detectedStores: Int
    let detectedCustomers: Int
    let detectedUnknown: Int
    let actualStores: Int
    let actualCustomers: Int
    let dotFound: Bool
    let ms: Int
}

@MainActor
final class PinCheckStore: ObservableObject {
    static let shared = PinCheckStore()
    @Published var items: [PinCheckItem] = []
    @Published private(set) var running = false
    @Published private(set) var skipped = 0
    private var saved: [UUID: PinCheckRecord] = [:]

    var json: String {
        (try? JSONEncoder().encode(Array(saved.values))).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
    var confirmedCount: Int { saved.count }

    func confirm(_ item: PinCheckItem) {
        saved[item.id] = PinCheckRecord(app: item.app, detectedStores: item.detectedStores, detectedCustomers: item.detectedCustomers,
                                        detectedUnknown: item.detectedUnknown, actualStores: item.stores, actualCustomers: item.customers,
                                        dotFound: item.dot != nil, ms: item.ms)
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].confirmed = true }
    }

    func run(_ picked: [PhotosPickerItem]) {
        guard !running, !picked.isEmpty else { return }
        running = true
        Task {
            for p in picked {
                if let data = try? await p.loadTransferable(type: Data.self), let image = UIImage(data: data)?.cgImage,
                   let item = Self.check(image) {
                    items.insert(item, at: 0)
                } else {
                    skipped += 1
                }
            }
            running = false
        }
    }

    private static let script: JSContext? = {
        guard let context = JSContext() else { return nil }
        for name in ["copilot", "screen-reader", "map-reader"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            context.evaluateScript(text)
        }
        return context
    }()

    /// The reader's pipeline on one screenshot: card → app and where the map ends; map crop at 400 px → pins.
    static func check(_ image: CGImage) -> PinCheckItem? {
        guard let context = script else { return nil }
        let start = Date()
        let lines = ReaderCompareStore.recognize(image, top: 0.4)
        let payload = lines.map { ["text": $0.text, "x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] as [String: Any] }
        guard let linesJSON = try? JSONSerialization.data(withJSONObject: payload),
              let text = context.objectForKeyedSubscript("ScreenReader")?.objectForKeyedSubscript("summarizeJSON")?
                .call(withArguments: [String(decoding: linesJSON, as: UTF8.self), RulesStore.current.settingsJSON, "{}"])?.toString(),
              let summary = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let platform = summary["platform"] as? String else { return nil }
        let mapBottom = ((summary["routing"] as? [String: Any])?["mapBottom"] as? Double) ?? 0.5
        let top = 0.055, bottom = max(0.2, min(mapBottom, 0.6))
        let H = Double(image.height), W = Double(image.width)
        guard let crop = image.cropping(to: CGRect(x: 0, y: H * top, width: W, height: H * (bottom - top))) else { return nil }
        // 400 px wide, RGBA, row 0 at the top — exactly what the screen reader hands the map reader.
        let width = 400, height = max(11, Int((Double(crop.height) * 400 / Double(crop.width)).rounded()))
        var pixels = Data(count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let cg = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            cg.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, let analyze = context.objectForKeyedSubscript("MapReader")?.objectForKeyedSubscript("analyzeJSON"),
              let out = analyze.call(withArguments: [pixels.base64EncodedString(), width, height, platform,
                                                     "{\"top\":\(top),\"height\":\(bottom - top)}", H / W, "[]"])?.toString(),
              let result = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
              let found = result["found"] as? [String: Any] else { return nil }
        // Back to the crop's own 0–1 coordinates for drawing.
        let toCrop = { (y: Double) in (y - top) / (bottom - top) }
        var pins: [(x: Double, y: Double, r: Double, kind: String)] = (found["pins"] as? [[String: Any]] ?? []).map { p in
            let kind = platform == "uber_eats" ? "customer" : (p["kind"] as? String) ?? "unknown"
            return ((p["centerX"] as? Double) ?? 0, toCrop((p["centerY"] as? Double) ?? 0), (p["radius"] as? Double) ?? 0.03, kind)
        }
        pins += (found["pickupPins"] as? [[String: Any]] ?? []).map { p in
            ((p["centerX"] as? Double) ?? 0, toCrop((p["centerY"] as? Double) ?? 0), (p["radius"] as? Double) ?? 0.03, "store")
        }
        let dot = (found["currentLocation"] as? [String: Any]).flatMap { d -> (x: Double, y: Double)? in
            guard let x = d["x"] as? Double, let y = d["y"] as? Double else { return nil }
            return (x, toCrop(y))
        }
        let item = PinCheckItem(app: platform, map: UIImage(cgImage: crop), pins: pins, dot: dot,
                                ms: Int(Date().timeIntervalSince(start) * 1000), stores: 0, customers: 0)
        var withCounts = item
        withCounts.stores = item.detectedStores
        withCounts.customers = item.detectedCustomers + item.detectedUnknown
        return withCounts
    }
}

/// Diagnostics → Map pin check.
struct PinCheckSection: View {
    @ObservedObject private var store = PinCheckStore.shared
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        Section {
            PhotosPicker(selection: $picked, maxSelectionCount: 20, matching: .screenshots) {
                Label(store.running ? "Checking…" : "Choose offer screenshots with maps", systemImage: "mappin.and.ellipse")
            }
            .disabled(store.running)
            .onChange(of: picked) { _, items in store.run(items); picked = [] }
            if store.skipped > 0 { Text("\(store.skipped) weren't offer cards with a map.").font(.footnote).foregroundStyle(.secondary) }
            if store.confirmedCount > 0 { Text("\(store.confirmedCount) checked. They go into your export.").font(.footnote).foregroundStyle(.secondary) }
            ForEach($store.items) { $item in PinCheckRow(item: $item) }
        } header: {
            Text("Map pin check")
        } footer: {
            Text("__APP_NAME__'s pin finder runs on each map: purple = store, green = customer, gray = unsure, blue = you. Set the real counts if it's wrong, then tap Save. Screenshots aren't kept.")
        }
    }
}

struct PinCheckRow: View {
    @Binding var item: PinCheckItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Theme.appName(item.app)) · found \(item.detectedStores) store, \(item.detectedCustomers) customer"
                 + (item.detectedUnknown > 0 ? ", \(item.detectedUnknown) unsure" : "") + (item.dot == nil ? " · no blue dot" : "")
                 + String(format: " · %.2f s", Double(item.ms) / 1000))
                .font(.caption.weight(.semibold))
            Image(uiImage: item.map).resizable().scaledToFit()
                .overlay {
                    GeometryReader { geo in
                        ForEach(Array(item.pins.enumerated()), id: \.offset) { _, pin in
                            Circle().stroke(color(pin.kind), lineWidth: 3)
                                .frame(width: max(18, pin.r * geo.size.width * 2.4), height: max(18, pin.r * geo.size.width * 2.4))
                                .position(x: pin.x * geo.size.width, y: pin.y * geo.size.height)
                        }
                        if let dot = item.dot {
                            Circle().stroke(Color.blue, lineWidth: 3).frame(width: 18, height: 18)
                                .position(x: dot.x * geo.size.width, y: dot.y * geo.size.height)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Stepper("Real store pins: \(item.stores)", value: $item.stores, in: 0...6)
            Stepper("Real customer pins: \(item.customers)", value: $item.customers, in: 0...8)
            Button(item.confirmed ? "Saved ✓" : "Save") { PinCheckStore.shared.confirm(item) }
                .disabled(item.confirmed)
        }
        .padding(.vertical, 4)
    }

    private func color(_ kind: String) -> Color {
        kind == "store" ? Theme.purple : kind == "customer" ? Theme.neonGreen : .gray
    }
}
