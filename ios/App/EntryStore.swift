import Foundation

/// Money added by hand from the ＋ sheet (user, Oct 15, after Gridwise): expenses, and tips, bonuses, and other
/// earnings that aren't an order's pay. Totals come from core/shift.js `rangeMetrics` (extras count in earnings, expenses
/// give net). Stored on the phone only; included in the export and restore.
struct MoneyEntry: Codable, Identifiable, Equatable {
    /// `imported` = a day's earnings from a Gridwise report (a daily total for one app: counts in earnings and the app share,
    /// never in $/hr or $/mi, which need time and miles).
    /// `mileage` = a day's hours and miles from a Gridwise Mileage report (amountCents = Gridwise's deduction for the day).
    enum Kind: String, Codable { case expense, extra, imported, mileage }
    let id: String
    var kind: Kind
    var at: Date
    var amountCents: Int
    var category: String
    /// The delivery app an extra came from (nil for expenses or "other").
    var platform: String?
    var note: String?
    /// Mileage entries only: miles ×1000 and seconds worked.
    var milliMiles: Int?
    var seconds: Int?

    static let expenseCategories = ["Gas", "Charging", "Car wash", "Maintenance", "Parking & tolls", "Phone", "Food & drinks", "Other"]
    static let extraCategories = ["Tip", "Bonus or challenge", "Pay adjustment", "Other"]
}

@MainActor
final class EntryStore: ObservableObject {
    static let shared = EntryStore()
    @Published private(set) var entries: [MoneyEntry] = []

    private init() { load() }

    func add(_ entry: MoneyEntry) {
        entries.append(entry)
        entries.sort { $0.at < $1.at }
        save()
    }

    func delete(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Restore from an export; entries already here are kept.
    func importEntries(_ incoming: [MoneyEntry]) -> Int {
        let known = Set(entries.map(\.id))
        let added = incoming.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return 0 }
        entries = (entries + added).sorted { $0.at < $1.at }
        save()
        return added.count
    }

    /// Removes everything imported from Gridwise (ids start "gw|"); returns how many.
    @discardableResult
    func removeImported() -> Int {
        let before = entries.count
        entries.removeAll { $0.id.hasPrefix("gw|") }
        save()
        return before - entries.count
    }

    var json: String { ShiftEngine.json(encodable: entries) }

    private var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("entries.json")
    }

    private func load() {
        guard !PreviewData.isActive, let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([MoneyEntry].self, from: data)) ?? []
    }

    private func save() {
        guard !PreviewData.isActive, let url = fileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(entries).write(to: url, options: .atomic)
    }
}
