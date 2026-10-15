import Foundation

/// Durable, append-only record of every offer seen (accepted or not), one JSON object per line, one file per month.
/// Roadmap §7–8: the training dataset grows from these records; later lifecycle events attach by `offerId`.
/// Stored in the App Group when the install has one (the app can read it), otherwise in the extension's own
/// container (kept, but not visible to the app). Offer fields and verdicts only: no screen text, images,
/// customer names, street addresses, or coordinates.
enum OfferJournal {
    static let schemaVersion = 1

    private static func folder() -> (url: URL, shared: Bool)? {
        let fm = FileManager.default
        if let group = try? AppGroup.container() {
            return (group.appendingPathComponent("journal", isDirectory: true), true)
        }
        guard let local = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return (local.appendingPathComponent("journal", isDirectory: true), false)
    }

    private static func fileName(_ prefix: String, for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%@-%04d-%02d.jsonl", prefix, parts.year ?? 0, parts.month ?? 0)
    }

    /// Appends one schema-1 record (fallback when the lifecycle script is unavailable). Failures are ignored: the
    /// journal must never stop reading or notifying.
    static func append(_ record: [String: Any], at date: Date = Date()) {
        var line = record
        line["v"] = schemaVersion
        line["recordedAt"] = ISO8601DateFormatter().string(from: date)
        write([line], to: "offers", at: date)
    }

    /// Appends schema-2 events from core/lifecycle.js (`offer_seen`, `prediction_made`, later lifecycle events) to
    /// `events-YYYY-MM.jsonl`. Never rewritten: the order record is derived from the events (addendum §8).
    static func appendEvents(_ events: [[String: Any]], at date: Date = Date()) {
        let stamp = ISO8601DateFormatter().string(from: date)
        write(events.map { $0.merging(["recordedAt": stamp]) { old, _ in old } }, to: "events", at: date)
    }

    private static func write(_ lines: [[String: Any]], to prefix: String, at date: Date) {
        guard let place = folder() else { return }
        var data = Data()
        for line in lines {
            guard JSONSerialization.isValidJSONObject(line),
                  let encoded = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { continue }
            data.append(encoded)
            data.append(0x0A)
        }
        guard !data.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: place.url, withIntermediateDirectories: true)
        let file = place.url.appendingPathComponent(fileName(prefix, for: date))
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Offer records readable by the app (App Group installs only), newest last: schema-1 records and schema-2
    /// `offer_seen` events (one per offer; predictions and lifecycle events are not counted).
    static func readShared(limit: Int = 2000) -> [[String: Any]] {
        guard let place = folder(), place.shared,
              let files = try? FileManager.default.contentsOfDirectory(at: place.url, includingPropertiesForKeys: nil) else { return [] }
        var records: [[String: Any]] = []
        for file in files.filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   ["offer.seen", "offer_seen"].contains(object["type"] as? String ?? "") {
                    records.append(object)
                }
            }
        }
        return Array(records.suffix(limit))
    }

    static var isShared: Bool { folder()?.shared ?? false }

    /// Every journal line this process can read (App Group, else its own container), oldest file first, for export.
    static func readAllLines() -> [String] {
        guard let place = folder(),
              let files = try? FileManager.default.contentsOfDirectory(at: place.url, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { file in
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix("{") }
        }
    }
}
