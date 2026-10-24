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
    struct Picky: Decodable, Equatable {
        let averageHourlyCents: Int?; let passed: Int; let beatAverage: Int; let failedPerMile: Int; let failedHourly: Int; let verdict: String?
    }
    struct Times: Decodable, Equatable { let orders: Int; let actual: Int; let guessed: Int?; let eta: Int? }
    /// Drive-back estimate vs the real drive back: miles off on average, average over (+) or under (−), share within 1 mi.
    struct Accuracy: Decodable, Equatable { let orders: Int; let off: Double; let bias: Double; let within1: Int }
    let mix: Mix
    let grid: [Cell]
    let perMile: PerMile
    let payoff: Payoff
    let picky: Picky
    let times: [String: Times]
    let accuracy: [String: Accuracy]
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
                        pickyCard(data.picky)
                        payoffCard(data.payoff)
                        timesCard(data.times)
                        accuracyCard(data.accuracy)
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

    private func card<Content: View>(_ title: String, _ caption: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let caption { Text(caption).font(.footnote).foregroundStyle(Theme.secondaryText) }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func mixCard(_ mix: Breakdown.Mix) -> some View {
        let slices: [(String, Int, Color)] = [("Accept", mix.accept, Theme.neonGreen), ("Maybe", mix.maybe, Theme.neonYellow),
                                              ("Decline", mix.decline, Theme.neonRed)] + (mix.unread > 0 ? [("Unread", mix.unread, Theme.track)] : [])
        return card("Offers", "Every offer __APP_NAME__ read, by its verdict.") {
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
        return card("When the good offers come", "Brighter squares had more offers that met your rules.") {
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
        card("$/mi with the drive back", "Pay ÷ all the miles, drive back included. Green bars meet your rate.") {
            PerMileChart(buckets: spread.buckets, rate: model.rules.centsPerMile)
            HStack {
                if let median = spread.median { stat(String(format: "$%.2f", Double(median) / 100), "middle offer") }
                stat(percent(spread.atOrAbove, of: spread.total), "at \(model.rules.perMileText)+")
            }
        }
    }

    private func payoffCard(_ payoff: Breakdown.Payoff) -> some View {
        card("Did taking it pay off", "Orders you finished: the $/hr __APP_NAME__ predicted and what you made. Both count the drive back.") {
            if payoff.orders == 0 {
                Text("Finished orders show up here.").foregroundStyle(Theme.secondaryText)
            } else {
                HStack {
                    stat(payoff.predicted.map(TripFormat.hourly) ?? "—", "predicted")
                    stat(payoff.actual.map(TripFormat.hourly) ?? "—", "actual")
                }
                Text(payoff.orders == 1 ? "1 order" : "\(payoff.orders) orders").font(.footnote).foregroundStyle(Theme.secondaryText)
                if payoff.against.orders > 0 {
                    Divider()
                    row("Took a Decline", payoff.against)
                    row("Followed __APP_NAME__", payoff.followed)
                }
            }
        }
    }

    /// Am I too picky? (user, Oct 23). While you wait, an offer that pays more per hour than you actually average online
    /// raises the average, so passing it costs you.
    private func pickyCard(_ picky: Breakdown.Picky) -> some View {
        card("Am I too picky?", "Offers you passed that paid more per hour than you really average online, waiting included.") {
            if let average = picky.averageHourlyCents, let verdict = picky.verdict {
                let (headline, color, advice): (String, Color, String) = switch verdict {
                case "too_picky": ("Yes, a bit too picky", Theme.neonYellow,
                                   "Taking these while you wait would likely raise your average. Try a lower hourly target.")
                case "a_little": ("A little", Theme.neonYellow, "Some offers you passed beat your average.")
                default: ("No, about right", Theme.neonGreen, "Your rules match what your market pays.")
                }
                Text(headline).font(.title2.weight(.heavy)).foregroundStyle(color)
                HStack {
                    stat(TripFormat.hourly(average), "your real average")
                    stat(percent(picky.beatAverage, of: picky.passed), "of passed offers beat it")
                }
                Text("\(picky.beatAverage) of \(picky.passed) passed offers. \(picky.failedHourly) of them met \(model.rules.perMileText)/mi "
                     + "and missed only \(model.rules.hourlyText); \(picky.failedPerMile) were under \(model.rules.perMileText)/mi.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                Text(advice).font(.subheadline)
            } else {
                Text("Needs an hour online and 20 passed offers with a $/hr.").foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// Trip times per app: __APP_NAME__'s prediction, the app's ETA you entered, and how long orders really took (Oct 23).
    private func timesCard(_ times: [String: Breakdown.Times]) -> some View {
        card("Trip times", "Average minutes from accepting to the last drop-off, on orders you finished.") {
            if times.isEmpty {
                Text("Finished orders show up here.").foregroundStyle(Theme.secondaryText)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Predicted"); Text("App said"); Text("Took")
                    }
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                    ForEach(["doordash", "uber_eats", "grubhub"].filter { times[$0] != nil }, id: \.self) { app in
                        let t = times[app]!
                        GridRow {
                            HStack(spacing: 6) { AppLogo(platform: app, size: 18); Text(Theme.appName(app)) }
                            Text(t.guessed.map { "\($0) min" } ?? "—")
                            Text(t.eta.map { "\($0) min" } ?? "—")
                            Text("\(t.actual) min").fontWeight(.bold)
                        }
                        .font(.subheadline.monospacedDigit())
                    }
                }
                Text("Enter the app's time on an order (tap it, Edit) and __APP_NAME__ learns how long that app's orders take.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// The reader grading itself (reader upgrade 1, Oct 23).
    private func accuracyCard(_ accuracy: [String: Breakdown.Accuracy]) -> some View {
        card("How accurate is the reader", "The drive back each verdict counted vs the real one from where you delivered.") {
            if accuracy.isEmpty {
                Text("Fills in as you finish orders.").foregroundStyle(Theme.secondaryText)
            } else {
                let names = ["map": "Map pins", "dropoff": "Drop-off street", "dropoff_town": "Town center", "worst_case": "Longest case"]
                ForEach(accuracy.keys.sorted { accuracy[$0]!.orders > accuracy[$1]!.orders }, id: \.self) { kind in
                    let a = accuracy[kind]!
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(names[kind] ?? kind.capitalized).font(.subheadline.weight(.semibold))
                            Text((a.orders == 1 ? "1 order" : "\(a.orders) orders") + " · "
                                 + (abs(a.bias) < 0.2 ? "no lean" : String(format: "%.1f mi too %@ on average", abs(a.bias), a.bias > 0 ? "long" : "short")))
                                .font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(a.within1)%").font(.title3.weight(.heavy).monospacedDigit())
                                .foregroundStyle(a.within1 >= 80 ? Theme.neonGreen : a.within1 >= 50 ? Theme.neonYellow : Theme.neonRed)
                            Text(String(format: "within 1 mi · off %.1f", a.off)).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func placesCard(_ places: Breakdown.Places) -> some View {
        card("Restaurants", "Share of each store's offers that met your rules, and your average wait there.") {
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
        let shifts = (ShiftStore.shared.history + [ShiftStore.shared.current].compactMap { $0 }).filter { !DemoData.isDemo($0.id) }
        let input = "{\"offers\":\(ShiftEngine.json(encodable: offers)),\"trips\":\(ShiftEngine.json(encodable: trips)),"
            + "\"shifts\":\(ShiftEngine.json(encodable: shifts)),\"entries\":\(EntryStore.shared.json),"
            + "\"restaurants\":\(RestaurantStore.shared.databaseJSON),\"filters\":\(ShiftEngine.json(filters)),"
            + "\"offsetMinutes\":\(ShiftEngine.offsetMinutes),\"centsPerMile\":\(model.rules.centsPerMile)}"
        let result = ShiftEngine.decode(Breakdown.self, ShiftEngine.call("breakdownJSON", [input]))
        if result != data { data = result }
    }
}

/// The $/mi histogram on its own, with the values worked out first (the compiler timed out on it inline, Oct 23).
struct PerMileChart: View {
    struct Bar: Identifiable { let id: Int; let low: Double; let high: Double; let count: Int; let meets: Bool }
    let bars: [Bar]
    let rate: Double

    init(buckets: [Breakdown.Bucket], rate: Int) {
        // Explicit start and end and a zero base: a bar on a number axis has neither of its own (screens, Oct 23).
        bars = buckets.map { b in
            Bar(id: b.from, low: Double(b.from) / 100 + 0.005, high: Double(b.from + 10) / 100 - 0.005, count: b.count, meets: b.from >= rate)
        }
        self.rate = Double(rate) / 100
    }

    var body: some View {
        Chart {
            ForEach(bars) { bar in
                RectangleMark(xStart: .value("From", bar.low), xEnd: .value("To", bar.high),
                              yStart: .value("Base", 0), yEnd: .value("Offers", bar.count))
                    .foregroundStyle(bar.meets ? Theme.neonGreen : Theme.secondaryText.opacity(0.45))
            }
            RuleMark(x: .value("Your rate", rate))
                .foregroundStyle(Theme.purple)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }
        .chartXScale(domain: 0.0...2.1)
        .chartXAxis {
            AxisMarks(values: [0.0, 0.5, 1.0, 1.5, 2.0]) { value in
                AxisGridLine().foregroundStyle(Theme.track)
                AxisValueLabel(anchor: .top) { Text(Self.label(value.as(Double.self) ?? 0)) }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 140)
    }

    private static func label(_ v: Double) -> String { v >= 2 ? "$2+" : String(format: "$%.2f", v) }
}
