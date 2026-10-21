import SwiftUI

/// How well the reader is doing per app, from real use (core/shift.js `readerHealth`; user, Oct 21: method 6).
struct ReaderHealth: Decodable, Equatable {
    struct Stats: Decodable, Equatable {
        let offers: Int, sure: Int, unsure: Int, unsureMap: Int, unsureNumbers: Int
        let unsureShare: Double?
    }
    struct App: Decodable, Equatable {
        let recent: Stats
        let fortnight: Stats
        let orders: Int
        let payFixed: Int
        /// Unsure readings jumped: the app may have changed its screens.
        let redesign: Bool
    }
    let doordash: App
    let uber_eats: App
    let grubhub: App

    func app(_ platform: String) -> App? {
        ["doordash": doordash, "uber_eats": uber_eats, "grubhub": grubhub][platform]
    }

    /// Apps whose reading suddenly got worse.
    var redesigned: [String] { ["doordash", "uber_eats", "grubhub"].filter { app($0)?.redesign == true } }

    @MainActor
    static func compute(offers: [LiveOffer], now: Date = Date()) -> ReaderHealth? {
        let since = now.addingTimeInterval(-15 * 86_400)
        let rows: [[String: Any]] = offers.filter { $0.seenAt >= since && !DemoData.isDemo($0.offerId) }.map { o in
            var row: [String: Any] = ["platform": o.platform, "seenAt": ISO8601DateFormatter().string(from: o.seenAt)]
            if let notice = o.notice { row["notice"] = notice }
            if let kind = o.returnKind { row["returnKind"] = kind }
            if let ret = o.returnMilliMiles { row["returnMilliMiles"] = ret }
            return row
        }
        let trips = (TripStore.shared.history + [TripStore.shared.active].compactMap { $0 }).filter { ($0.endedAt ?? now) >= since }
        let input = "{\"offers\":\(ShiftEngine.json(rows)),\"trips\":\(ShiftEngine.json(encodable: trips)),"
            + "\"now\":\(ShiftEngine.json(ISO8601DateFormatter().string(from: now)))}"
        return ShiftEngine.decode(ReaderHealth.self, ShiftEngine.call("readerHealthJSON", [input]))
    }
}

/// Diagnostics: one row per app — sure verdicts, why some weren't, pay fixes — over 2 and 14 days.
struct ReaderHealthSection: View {
    let health: ReaderHealth

    var body: some View {
        Section {
            ForEach(["doordash", "uber_eats", "grubhub"], id: \.self) { platform in
                if let app = health.app(platform), app.fortnight.offers > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            AppLogo(platform: platform, size: 20)
                            Text(Theme.appName(platform)).font(.headline)
                            Spacer()
                            Text(Self.percent(app.recent.offers > 0 ? app.recent : app.fortnight) + " sure").monospacedDigit()
                        }
                        Text("Last 2 days: \(app.recent.offers) offers, \(app.recent.unsure) unsure (map \(app.recent.unsureMap), numbers \(app.recent.unsureNumbers))")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                        Text("14 days: \(Self.percent(app.fortnight)) sure of \(app.fortnight.offers) · pay fixed on \(app.payFixed) of \(app.orders) orders")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                        if app.redesign {
                            Label("Reading got worse: the app may have changed its screens", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }
                }
            }
        } header: {
            Text("Reader accuracy")
        } footer: {
            Text("Sure = Accept or Decline. Unsure = the drop-off couldn't be placed, or the card's numbers didn't fit.")
        }
    }

    static func percent(_ s: ReaderHealth.Stats) -> String {
        s.offers > 0 ? "\(Int((Double(s.sure) / Double(s.offers) * 100).rounded()))%" : "—"
    }
}
