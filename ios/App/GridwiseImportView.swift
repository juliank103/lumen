import SwiftUI
import UniformTypeIdentifiers

/// What core/shift.js `parseGridwise` returns for one Gridwise CSV report.
struct GridwiseReport: Decodable, Equatable {
    struct Skip: Decodable, Equatable { let line: Int; let reason: String }
    struct Totals: Decodable, Equatable {
        let earningsCents: Int
        let expensesCents: Int
        let byPlatform: [String: Int]
        let byCategory: [String: Int]
        /// Mileage report only.
        let miles: Double?
        let seconds: Int?
        let deductionCents: Int?
    }
    /// "earnings", "expenses", "mileage", or nil when the file isn't one of Gridwise's reports.
    let kind: String?
    let entries: [MoneyEntry]
    let skipped: [Skip]
    let from: String?
    let to: String?
    let totals: Totals
}

extension GridwiseReport {
    /// Reads one report's text through core/shift.js. Entries carry ISO dates, so this needs the .iso8601 strategy
    /// (ShiftEngine.decode's default decoder rejected every row: build 26's "That isn't a Gridwise report" on a good file,
    /// user Oct 19). Covered by a unit test that decodes real parser output.
    @MainActor
    static func parse(_ text: String) -> Result<GridwiseReport, Error> {
        let options = "{\"offsetMinutes\":\(ShiftEngine.offsetMinutes)}"
        guard let json = ShiftEngine.call("parseGridwiseJSON", [ShiftEngine.json(text), options]) else {
            return .failure(NSError(domain: "Gridwise", code: 1, userInfo: [NSLocalizedDescriptionKey: "the importer didn't run"]))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Result { try decoder.decode(GridwiseReport.self, from: Data(json.utf8)) }
    }
}

/// Import history from Gridwise (user, Oct 19: "allow myself and future users to import their data from gridwise").
/// Choose the Earnings report and/or the Expenses report (CSV) saved to Files; __APP_NAME__ shows what's in each, then adds
/// it. Daily earnings count in Earnings and the By app split but have no hours or miles, so they stay out of $/hr and
/// $/mi; a day and app __APP_NAME__ tracked itself uses its own orders. Importing a report again adds nothing twice.
struct GridwiseImportView: View {
    private struct Loaded: Identifiable {
        let id = UUID()
        let name: String
        let report: GridwiseReport?
        /// Why a file that looks like a report couldn't be read (nil: simply not one of Gridwise's reports).
        var problem: String? = nil
    }

    @ObservedObject private var store = EntryStore.shared
    @State private var picking = false
    @State private var files: [Loaded] = []
    @State private var result: String?
    @State private var confirmRemove = false

    private var allNew: [MoneyEntry] {
        let known = Set(store.entries.map(\.id))
        var seen = Set<String>()
        return files.compactMap(\.report).flatMap(\.entries).filter { !known.contains($0.id) && seen.insert($0.id).inserted }
    }

    var body: some View {
        List {
            Section {
                Text("In Gridwise, export your Earnings, Expenses, and Mileage reports as CSV and save them to Files or iCloud Drive. Choose both here at once, or one at a time.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { picking = true } label: { Label("Choose CSV files…", systemImage: "doc.badge.plus") }
            }
            ForEach(files) { file in
                Section { fileSummary(file) } header: { Text(file.name) }
            }
            if !files.isEmpty {
                Section {
                    if let result {
                        Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button { add() } label: {
                            Text(allNew.isEmpty ? "Nothing new to add" : "Add \(allNew.count) entries").font(.headline)
                        }
                        .disabled(allNew.isEmpty)
                    }
                } footer: {
                    Text("Earnings from Gridwise are daily totals per app. They appear under Earnings by day and in the By app split. Expenses go to Net and the expense tile. Mileage adds hours and miles for those days, which gives imported earnings a $/hr and $/mi.")
                }
            }
            if importedCount > 0 {
                Section {
                    Button("Remove everything imported from Gridwise", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("\(importedCount) imported entries are on this phone. Entries you added yourself are not touched.")
                }
            }
        }
        .navigationTitle("Import from Gridwise")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .text], allowsMultipleSelection: true) { outcome in
            guard case .success(let urls) = outcome else { return }
            files = urls.map(load)
            result = nil
        }
        .confirmationDialog("Remove imported data?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove \(importedCount) entries", role: .destructive) {
                let removed = store.removeImported()
                result = "Removed \(removed) imported entries."
                files = []
            }
        }
    }

    private var importedCount: Int { store.entries.filter { $0.id.hasPrefix("gw|") }.count }

    @ViewBuilder private func fileSummary(_ file: Loaded) -> some View {
        if let report = file.report, let kind = report.kind {
            let known = Set(store.entries.map(\.id))
            let fresh = report.entries.filter { !known.contains($0.id) }.count
            row(["earnings": "Earnings report", "expenses": "Expenses report", "mileage": "Mileage report"][kind] ?? "Report", Self.range(report.from, report.to))
            if kind == "mileage" {
                row("Days", "\(report.entries.count)")
                row("Hours", String(format: "%.1f", Double(report.totals.seconds ?? 0) / 3600))
                row("Miles", String(format: "%.1f", report.totals.miles ?? 0))
                row("Deduction (Gridwise's rates)", ShiftFormat.money(report.totals.deductionCents ?? 0), bold: true)
            } else if kind == "earnings" {
                row("Daily totals", "\(report.entries.count)")
                ForEach(report.totals.byPlatform.sorted { $0.value > $1.value }, id: \.key) { app, cents in
                    HStack(spacing: 8) {
                        AppLogo(platform: app, size: 20)
                        Text(Theme.appName(app))
                        Spacer()
                        Text(ShiftFormat.money(cents)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                row("Total earnings", ShiftFormat.money(report.totals.earningsCents), bold: true)
            } else {
                row("Expenses", "\(report.entries.count)")
                ForEach(report.totals.byCategory.sorted { $0.value > $1.value }, id: \.key) { category, cents in
                    row(category, ShiftFormat.money(cents))
                }
                row("Total expenses", ShiftFormat.money(report.totals.expensesCents), bold: true)
            }
            if fresh < report.entries.count { row("Already on this phone", "\(report.entries.count - fresh)") }
            if !report.skipped.isEmpty {
                row("Skipped", "\(report.skipped.count) (zero or unreadable rows)")
            }
        } else {
            Label(file.problem ?? "That isn't one of Gridwise's Earnings, Expenses, or Mileage reports. It needs a Date column, and Amount (or Hours and Miles).",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(value).foregroundStyle(bold ? .primary : .secondary).fontWeight(bold ? .semibold : .regular).multilineTextAlignment(.trailing)
        }
    }

    private func load(_ url: URL) -> Loaded {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return Loaded(name: url.lastPathComponent, report: nil)
        }
        switch GridwiseReport.parse(text) {
        case .success(let report):
            return Loaded(name: url.lastPathComponent, report: report.kind == nil ? nil : report)
        case .failure(let error):
            return Loaded(name: url.lastPathComponent, report: nil, problem: "__APP_NAME__ couldn't read this report: \(error.localizedDescription)")
        }
    }

    private func add() {
        let added = store.importEntries(allNew)
        result = "Added \(added) entries. Look under Earnings, by week or day."
    }

    private static func range(_ from: String?, _ to: String?) -> String {
        guard let from, let to else { return "" }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        let shown = DateFormatter()
        shown.dateStyle = .medium
        shown.timeZone = TimeZone(identifier: "UTC")
        guard let a = parser.date(from: from), let b = parser.date(from: to) else { return from + " – " + to }
        return shown.string(from: a) + " – " + shown.string(from: b)
    }
}
