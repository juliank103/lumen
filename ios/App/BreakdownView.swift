import SwiftUI
import Charts

/// The Breakdown page (user, Oct 23): every offer ever as Accept / Maybe / Decline, filtered by time of day, day of week
/// and app; when the good offers come (day × hour); the spread of $/mi against the driver's rate; whether taking orders
/// paid what __APP_NAME__ predicted; and the restaurants whose offers pass most and least. Numbers from core/shift.js
/// `breakdown`.
struct Breakdown: Decodable, Equatable {
    struct Mix: Decodable, Equatable { let accept: Int, maybe: Int, decline: Int, unread: Int, total: Int }
    struct Cell: Decodable, Equatable { let weekday: Int, hour: Int, offers: Int, good: Int }
    struct Bucket: Decodable, Equatable { let from: Int; let to: Int?; let count: Int }
    struct PerMile: Decodable, Equatable { let buckets: [Bucket]; let total: Int; let atOrAbove: Int; let median: Int? }
    struct Side: Decodable, Equatable { let orders: Int; let actual: Int? }
    struct Payoff: Decodable, Equatable { let orders: Int; let predicted: Int?; let actual: Int?; let followed: Side; let against: Side }
    struct Place: Decodable, Equatable { let name: String; let offers: Int; let good: Int; let rate: Int; let waitMinutes: Double? }
    struct Places: Decodable, Equatable { let best: [Place]; let worst: [Place] }
    let mix: Mix
    let grid: [Cell]
    let perMile: PerMile
    let payoff: Payoff
    let restaurants: Places
}

struct BreakdownView: View {
    @EnvironmentObject private var model: AppModel
    @State private var part = "all"
    @State private var weekdays: Set<Int> = []
    @State private var platform = "all"
    @State private var data: Breakdown?

    private static let parts: [(key: String, label: String)] = [("all", "All day"), ("breakfast", "Breakfast"), ("lunch", "Lunch"),
                                                                ("dinner", "Dinner"), ("late_night", "Late night"), ("early_morning", "Early morning")]
    private static let dayLetters = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    filters
                    if let data {
                        mixCard(data.mix)
                        gridCard(data.grid)
                        perMileCard(data.perMile)
                        payoffCard(data.payoff)
                        placesCard(data.restaurants)
                    } else {
                        Text("No offers yet.").foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding()
            }
            .navigationTitle("Breakdown")
            .navigationBarTitleDisplayMode(.inline)
            .menuButton()
        }
        .sensoryFeedback(.selection, trigger: part)
        .sensoryFeedback(.selection, trigger: weekdays)
        .sensoryFeedback(.selection, trigger: platform)
        .onAppear(perform: recompute)
        .onChange(of: part) { recompute() }
        .onChange(of: weekdays) { recompute() }
        .onChange(of: platform) { recompute() }
    }

    // MARK: Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Time of day", selection: $part) {
                    ForEach(Self.parts, id: \.key) { Text($0.label).tag($0.key) }
                }
                Spacer()
                Picker("App", selection: $platform) {
                    Text("All apps").tag("all")
                    ForEach(["doordash", "uber_eats", "grubhub"], id: \.self) { Text(Theme.appName($0)).tag($0) }
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { day in
                    let on = weekdays.contains(day)
                    Button {
                        if on { weekdays.remove(day) } else { weekdays.insert(day) }
                    } label: {
                        Text(Self.dayLetters[day]).font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity).frame(height: 36)
                            .foregroundStyle(on ? Theme.ground : .primary)
                            .background(on ? Theme.purple : Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[day])
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if !weekdays.isEmpty {
                Button("All days") { weekdays = [] }.font(.footnote.weight(.semibold))
            }
        }
    }

    // MARK: Cards

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func mixCard(_ mix: Breakdown.Mix) -> some View {
        let slices: [(String, Int, Color)] = [("Accept", mix.accept, Theme.neonGreen), ("Maybe", mix.maybe, Theme.neonYellow),
                                              ("Decline", mix.decline, Theme.neonRed)] + (mix.unread > 0 ? [("Unread", mix.unread, Theme.track)] : [])
        return card("Offers") {
            HStack(spacing: 20) {
                Chart(slices, id: \.0) { slice in
                    SectorMark(angle: .value("Offers", slice.1), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(slice.2)
                }
                .frame(width: 150, height: 150)
                .overlay {
                    VStack(spacing: 0) {
                        Text("\(mix.total)").font(.system(size: 30, weight: .heavy, design: .rounded))
                        Text("offers").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(slices, id: \.0) { slice in
                        HStack(spacing: 8) {
                            Circle().fill(slice.2).frame(width: 10, height: 10)
                            Text(slice.0).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(percent(slice.1, of: mix.total)).font(.subheadline.weight(.bold).monospacedDigit())
                        }
                    }
                }
            }
        }
    }

    /// Day × hour: brighter where more offers were worth accepting.
    private func gridCard(_ grid: [Breakdown.Cell]) -> some View {
        let most = max(1, grid.map(\.good).max() ?? 1)
        return card("When the good offers come") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                    HStack(spacing: 2) {
                        Text(Self.dayLetters[day]).font(.caption2.weight(.bold)).foregroundStyle(Theme.secondaryText).frame(width: 14)
                        ForEach(grid.filter { $0.weekday == day }, id: \.hour) { cell in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(cell.good > 0 ? Theme.neonGreen.opacity(0.25 + 0.75 * Double(cell.good) / Double(most))
                                      : cell.offers > 0 ? Theme.raised : Theme.track.opacity(0.4))
                                .frame(height: 14)
                        }
                    }
                }
                HStack {
                    Text("").frame(width: 14)
                    ForEach(["12a", "6a", "12p", "6p"], id: \.self) { Text($0).font(.caption2).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bestHours(grid))
            Text(bestHours(grid)).font(.footnote).foregroundStyle(Theme.secondaryText)
        }
    }

    private func perMileCard(_ spread: Breakdown.PerMile) -> some View {
        let rate = model.rules.centsPerMile
        return card("$/mi with the drive back") {
            Chart(spread.buckets, id: \.from) { bucket in
                BarMark(x: .value("$/mi", Double(bucket.from) / 100 + 0.05), y: .value("Offers", bucket.count), width: .ratio(0.85))
                    .foregroundStyle(bucket.from >= rate ? Theme.neonGreen : Theme.raised)
                RuleMark(x: .value("Your rate", Double(rate) / 100))
                    .foregroundStyle(Theme.purple).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            .chartXAxis {
                AxisMarks(values: [0, 0.5, 1, 1.5, 2]) { value in
                    AxisGridLine().foregroundStyle(Theme.track)
                    AxisValueLabel { if let v = value.as(Double.self) { Text(v >= 2 ? "$2+" : String(format: "$%.2g", v)) } }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 140)
            HStack {
                if let median = spread.median { stat(String(format: "$%.2f", Double(median) / 100), "middle offer") }
                stat(percent(spread.atOrAbove, of: spread.total), "at \(model.rules.perMileText)+")
            }
        }
    }

    private func payoffCard(_ payoff: Breakdown.Payoff) -> some View {
        card("Did taking it pay off") {
            if payoff.orders == 0 {
                Text("Finished orders show up here.").foregroundStyle(Theme.secondaryText)
            } else {
                HStack {
                    stat(payoff.predicted.map(TripFormat.hourly) ?? "—", "predicted")
                    stat(payoff.actual.map(TripFormat.hourly) ?? "—", "actual")
                }
                Text("\(payoff.orders) finished orders").font(.footnote).foregroundStyle(Theme.secondaryText)
                if payoff.against.orders > 0 {
                    Divider()
                    row("Took a Decline", payoff.against)
                    row("Followed __APP_NAME__", payoff.followed)
                }
            }
        }
    }

    private func placesCard(_ places: Breakdown.Places) -> some View {
        card("Restaurants") {
            if places.best.isEmpty && places.worst.isEmpty {
                Text("Restaurants with 3+ offers show up here.").foregroundStyle(Theme.secondaryText)
            } else {
                if !places.best.isEmpty { placeList("Pass most", places.best, Theme.neonGreen) }
                if !places.worst.isEmpty { placeList("Pass least", places.worst, Theme.neonRed) }
            }
        }
    }

    private func placeList(_ title: String, _ list: [Breakdown.Place], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            ForEach(list, id: \.name) { place in
                HStack {
                    Text(ZonesView.short(place.name)).lineLimit(1)
                    Spacer()
                    if let wait = place.waitMinutes {
                        Label("\(Int(wait.rounded())) min", systemImage: "clock").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Text("\(place.rate)%").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(color).frame(width: 48, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Helpers

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 26, weight: .heavy, design: .rounded))
            Text(label).font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ side: Breakdown.Side) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text((side.actual.map(TripFormat.hourly) ?? "—") + " · \(side.orders)").font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    private func percent(_ part: Int, of total: Int) -> String {
        total > 0 ? "\(Int((Double(part) / Double(total) * 100).rounded()))%" : "—"
    }

    /// "Best: Tue 6 PM, Wed 11 AM, Thu 3 PM" — the three hours with the most offers worth accepting.
    private func bestHours(_ grid: [Breakdown.Cell]) -> String {
        let top = grid.filter { $0.good > 0 }.sorted { ($0.good, $0.offers) > ($1.good, $1.offers) }.prefix(3)
        guard !top.isEmpty else { return "No accepted-worthy offers yet." }
        let names = Calendar.current.shortWeekdaySymbols
        return "Best: " + top.map { cell in
            let hour = cell.hour % 12 == 0 ? 12 : cell.hour % 12
            return "\(names[cell.weekday]) \(hour) \(cell.hour < 12 ? "AM" : "PM")"
        }.joined(separator: ", ")
    }

    private func recompute() {
        let offers = PreviewData.isActive ? PreviewData.breakdownOffers : model.offers.filter { !DemoData.isDemo($0.offerId) }
        let trips = (TripStore.shared.history + [TripStore.shared.active].compactMap { $0 }).filter { !DemoData.isDemo($0.id) }
        let filters: [String: Any] = ["part": part, "weekdays": weekdays.sorted(), "platform": platform]
        let input = "{\"offers\":\(ShiftEngine.json(encodable: offers)),\"trips\":\(ShiftEngine.json(encodable: trips)),"
            + "\"restaurants\":\(RestaurantStore.shared.databaseJSON),\"filters\":\(ShiftEngine.json(filters)),"
            + "\"offsetMinutes\":\(ShiftEngine.offsetMinutes),\"centsPerMile\":\(model.rules.centsPerMile)}"
        let result = ShiftEngine.decode(Breakdown.self, ShiftEngine.call("breakdownJSON", [input]))
        if result != data { data = result }
    }
}
