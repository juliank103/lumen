import SwiftUI
import UniformTypeIdentifiers

/// Export the driver's own history (user, Oct 14): CSV tables (offers with verdict and outcome, orders, trip steps,
/// restaurant waits, shifts, restaurants) plus one JSON file with everything, including the journal events. Files are
/// written to a temporary folder and shared through the system sheet (Save to Files, AirDrop, Mail, …).
struct ExportButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var files: [URL] = []
    @State private var failed = false

    var body: some View {
        if files.isEmpty {
            Button { prepare() } label: { Label("Export my data", systemImage: "square.and.arrow.up") }
                .font(.headline)
            if failed { Text("Export could not be prepared.").font(.caption).foregroundStyle(.orange) }
        } else {
            ShareLink(items: files) { Label("Share \(files.count) files (CSV + JSON)", systemImage: "square.and.arrow.up.on.square") }
                .font(.headline)
        }
    }

    private func prepare() {
        // Demo data stays out of exports.
        let trips = (TripStore.shared.history + [TripStore.shared.active].compactMap { $0 }).filter { !DemoData.isDemo($0.id) }
        let shifts = (ShiftStore.shared.history + [ShiftStore.shared.current].compactMap { $0 }).filter { !DemoData.isDemo($0.id) }
        let shiftRows: [[String: Any]] = shifts.map { shift in
            var row = (try? JSONSerialization.jsonObject(with: Data(ShiftEngine.json(encodable: shift).utf8))) as? [String: Any] ?? [:]
            row["finalMetrics"] = nil
            if let text = shift.finalMetrics ?? ShiftStore.shared.metricsJSON(for: shift, now: shift.endedAt ?? Date()),
               let metrics = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { row["metrics"] = metrics }
            return row
        }
        let offersJSON = ShiftEngine.json(encodable: model.offers.filter { !DemoData.isDemo($0.offerId) })
        let tripsJSON = ShiftEngine.json(encodable: trips)
        let data = "{\"offers\":\(offersJSON),\"trips\":\(tripsJSON),\"shifts\":\(ShiftEngine.json(shiftRows)),"
            + "\"restaurants\":\(RestaurantStore.shared.databaseJSON),\"entries\":\(EntryStore.shared.json),\"offsetMinutes\":\(ShiftEngine.offsetMinutes)}"
        guard let tablesText = ShiftEngine.call("exportTablesJSON", [data]),
              let tables = try? JSONSerialization.jsonObject(with: Data(tablesText.utf8)) as? [String: String] else { failed = true; return }
        let stamp = Date().formatted(.iso8601.year().month().day())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen export \(stamp)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var urls: [URL] = []
            for name in tables.keys.sorted() {
                let url = folder.appendingPathComponent(name)
                try tables[name]!.write(to: url, atomically: true, encoding: .utf8)
                urls.append(url)
            }
            // Everything in one file, including the journal (offer_seen / prediction_made / lifecycle events).
            let journal = "[" + OfferJournal.readAllLines().joined(separator: ",") + "]"
            let everything = "{\"exportedAt\":\(ShiftEngine.json(ISO8601DateFormatter().string(from: Date()))),"
                + "\"offers\":\(offersJSON),\"trips\":\(tripsJSON),\"shifts\":\(ShiftEngine.json(shiftRows)),"
                + "\"restaurants\":\(RestaurantStore.shared.databaseJSON),\"entries\":\(EntryStore.shared.json),\"journal\":\(journal)}"
            let url = folder.appendingPathComponent("lumen-history.json")
            try everything.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
            files = urls
            failed = false
        } catch {
            failed = true
        }
    }
}

/// Restore from an export (`lumen-history.json`, e.g. saved to iCloud Drive) after a reinstall: adds the offers,
/// trips, and shifts this install doesn't have, the restaurant list if this install has none, and the journal if it's
/// empty. Nothing already here is changed.
struct RestoreButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var picking = false
    @State private var result: String?

    var body: some View {
        Button { picking = true } label: { Label("Restore from a backup", systemImage: "arrow.down.doc") }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { outcome in
                guard case .success(let url) = outcome else { return }
                result = restore(url)
            }
            .alert("Restore", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
                Button("OK") { result = nil }
            } message: {
                Text(result ?? "")
            }
    }

    private func restore(_ url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "That file isn't a Lumen backup. Choose lumen-history.json from an export."
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func decode<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            guard let value = root[key], let json = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? decoder.decode(type, from: json)
        }
        guard root["offers"] != nil || root["trips"] != nil else {
            return "That file isn't a Lumen backup. Choose lumen-history.json from an export."
        }
        let offers = model.importOffers(decode("offers", [LiveOffer].self) ?? [])
        let trips = TripStore.shared.importTrips(decode("trips", [Trip].self) ?? [])
        let shifts = ShiftStore.shared.importShifts(decode("shifts", [Shift].self) ?? [])
        let entries = EntryStore.shared.importEntries(decode("entries", [MoneyEntry].self) ?? [])
        var restaurants = false
        if let db = root["restaurants"], !(db is NSNull), let json = try? JSONSerialization.data(withJSONObject: db),
           let text = String(data: json, encoding: .utf8) {
            restaurants = RestaurantStore.shared.restore(text)
        }
        var journal = 0
        if OfferJournal.readAllLines().isEmpty, let lines = root["journal"] as? [[String: Any]] {
            OfferJournal.appendEvents(lines)
            journal = lines.count
        }
        RestaurantStore.shared.update(offers: model.offers, trips: TripStore.shared.history + [TripStore.shared.active].compactMap { $0 })
        return "Added \(offers) offers, \(trips) trips, \(shifts) shifts" + (entries > 0 ? ", \(entries) expenses or extra earnings" : "") + (restaurants ? ", plus your restaurant list" : "")
            + (journal > 0 ? " and \(journal) history events" : "") + ". Anything already on this phone was kept."
    }
}
