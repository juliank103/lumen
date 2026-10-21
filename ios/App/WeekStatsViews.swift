import SwiftUI
import Charts

/// Stats by week, laid out like Gridwise's week page (user's screen recording, Oct 15): ‹ calendar › in the top bar,
/// the week's dates, a card of metric tiles that also pick what the Mon–Sun chart shows, an Efficiency strip, the days
/// as a list, then breakdowns and history. Past weeks get a Weekly recap (week-over-week, best day, top groups).
struct StatsTab: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var week = WeekModel()
    @ObservedObject private var shifts = ShiftStore.shared
    @ObservedObject private var restaurants = RestaurantStore.shared
    @State private var metric = ChartMetric.earnings
    @State private var selectedDay: Int?
    @State private var chartByApp = false
    @State private var editingGoal = false
    @State private var confirmEnd = false
    @State private var pickingDate = false
    @State private var editingShift: ShiftEditTarget?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(week.longTitle).font(.headline).foregroundStyle(.secondary)
                        Spacer()
                        if week.isCurrentWeek {
                            Text("This week").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Button("This week") { change { week.jumpToThisWeek() } }.font(.subheadline.weight(.semibold))
                        }
                    }
                    if let stats = week.stats {
                        if !week.isCurrentWeek, stats.week.completed > 0 {
                            NavigationLink { WeeklyRecapView(stats: stats, dates: week.days, title: week.longTitle) } label: {
                                HistoryRow(title: "Weekly recap", icon: "doc.text", value: "")
                            }
                            .buttonStyle(.plain)
                            .dasherCard()
                        }
                        VStack(spacing: 0) {
                            MetricTiles(week: stats.week, selection: $metric)
                            Picker("Chart", selection: $chartByApp) {
                                Text("By day").tag(false)
                                Text("By app").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 16).padding(.top, 14)
                            if chartByApp {
                                AppShareDonut(week: stats.week).padding(.horizontal, 16).padding(.top, 18)
                            } else {
                                WeekBarChart(days: stats.days, dates: week.days, metric: metric, today: week.todayIndex, selected: $selectedDay)
                                    .padding(.horizontal, 16).padding(.top, 18)
                                if let index = selectedDay, index < stats.days.count, index < week.days.count {
                                    SelectedDayRow(day: stats.days[index], date: week.days[index])
                                        .padding(.horizontal, 16).padding(.top, 6)
                                }
                            }
                        }
                        .padding(.bottom, 14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        WeekGoalRow(week: stats.week, editing: $editingGoal)
                        RatesLine(week: stats.week).padding(.horizontal, 4)
                        ByDayList(stats: stats, dates: week.days)
                        AppShareList(week: stats.week)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
            // Swipe sideways to change weeks.
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > 90, abs(dx) > abs(dy) * 2 else { return }
                change { week.move(dx < 0 ? 1 : -1) }
            })
            .navigationBarTitleDisplayMode(.inline)
            .menuButton()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 30) {
                        Button { change { week.move(-1) } } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Previous week")
                        Button { pickingDate = true } label: { Image(systemName: "calendar") }
                            .accessibilityLabel("Choose a week")
                        Button { change { week.move(1) } } label: { Image(systemName: "chevron.right") }
                            .disabled(!week.canGoForward)
                            .accessibilityLabel("Next week")
                    }
                    .font(.body.weight(.semibold))
                }
                ToolbarItem(placement: .topBarTrailing) { AddButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let current = shifts.current {
                            Button("Edit shift times…") { editingShift = ShiftEditTarget(shift: current) }
                        } else {
                            if let last = shifts.history.last {
                                Button("Edit last shift's times…") { editingShift = ShiftEditTarget(shift: last) }
                            }
                        }
                        Button("Goals…") { editingGoal = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("More options")
                }
            }
            .sheet(item: $editingShift) { target in ShiftEditor(shift: target.shift) }
            .sheet(isPresented: $pickingDate) {
                WeekPicker(start: week.weekStart) { date in change { week.jump(to: date) } }
                    .presentationDetents([.medium])
            }
            .goalEditor(isPresented: $editingGoal)
            .sensoryFeedback(.selection, trigger: week.offset)
            .sensoryFeedback(.selection, trigger: chartByApp)
            .sensoryFeedback(.selection, trigger: metric)
            .confirmationDialog("End this shift?", isPresented: $confirmEnd) {
                Button("End shift", role: .destructive) { shifts.end() }
            } message: {
                Text("It also ends by itself 30 minutes after offer reading stops with no trip running.")
            }
            .onAppear {
                week.offers = model.offers
                week.compute()
                if selectedDay == nil { selectedDay = week.todayIndex }
            }
            .onReceive(shifts.$metrics) { _ in
                guard week.isCurrentWeek else { return }
                week.offers = model.offers
                week.compute()
            }
            .onReceive(EntryStore.shared.$entries.dropFirst()) { _ in
                week.offers = model.offers
                week.compute()
            }
        }
    }

    private func change(_ action: () -> Void) {
        withAnimation(.easeInOut(duration: 0.2)) {
            action()
            selectedDay = week.todayIndex
        }
    }

}

/// Choose any past date; its week is shown.
struct WeekPicker: View {
    @Environment(\.dismiss) private var dismiss
    let start: Date
    let onPick: (Date) -> Void
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Week of", selection: $date, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .navigationTitle("Go to week")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Show") { onPick(date); dismiss() } }
                }
                .onAppear { date = start }
        }
    }
}

struct HistoryRow: View {
    let title: String
    let icon: String
    let value: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.purple).frame(width: 28)
            Text(title).font(.body)
            Spacer()
            Text(value).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: Metric tiles (they pick the chart's metric)

enum ChartMetric: String, CaseIterable, Identifiable {
    case earnings = "Earnings", expenses = "Expenses", net = "Net income", hours = "Hours", miles = "Miles",
         deduction = "Deduction", orders = "Orders", active = "On deliveries",
         idle = "Idle", deadhead = "Deadhead", wait = "Store wait", perHour = "Per hour", perMile = "Per mile"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .earnings: return "dollarsign.circle"
        case .expenses: return "minus.circle"
        case .net: return "banknote"
        case .deduction: return "doc.text"
        case .hours: return "hourglass"
        case .miles: return "gauge.with.dots.needle.50percent"
        case .orders: return "bag"
        case .active: return "car"
        case .idle: return "pause.circle"
        case .deadhead: return "arrow.uturn.backward"
        case .wait: return "fork.knife"
        case .perHour: return "clock"
        case .perMile: return "road.lanes"
        }
    }

    func value(_ m: RangeMetrics) -> Double {
        switch self {
        case .earnings: return Double(m.earningsCents) / 100
        case .expenses: return Double(m.expensesCents ?? 0) / 100
        case .net: return Double(m.netCents ?? m.earningsCents) / 100
        case .deduction: return Double(Self.deductionCents(m)) / 100
        case .perHour: return Double(m.perOnlineHourCents ?? 0) / 100
        case .perMile: return Double(m.perMileCents ?? 0) / 100
        case .hours: return Double(m.onlineSeconds) / 3600
        case .active: return Double(m.activeSeconds) / 3600
        case .miles: return m.miles.total
        case .orders: return Double(m.completed)
        case .deadhead: return m.miles.deadhead
        case .idle: return Double(m.idleSeconds) / 3600
        case .wait: return m.restaurantWait.averageMinutes ?? 0
        }
    }

    /// The tile's full value for the week.
    func tile(_ m: RangeMetrics) -> String {
        switch self {
        case .earnings: return ShiftFormat.money(m.earningsCents)
        case .expenses: return ShiftFormat.money(m.expensesCents ?? 0)
        case .net: return ShiftFormat.money(m.netCents ?? m.earningsCents)
        case .deduction: return ShiftFormat.money(Self.deductionCents(m))
        case .perHour: return ShiftFormat.rate(m.perOnlineHourCents, "hr")
        case .perMile: return ShiftFormat.rate(m.perMileCents, "mi")
        case .hours: return String(format: "%.1f", Double(m.onlineSeconds) / 3600)
        case .active: return String(format: "%.1f", Double(m.activeSeconds) / 3600)
        case .idle: return String(format: "%.1f", Double(m.idleSeconds) / 3600)
        case .miles: return String(format: "%.1f", m.miles.total)
        case .deadhead: return String(format: "%.1f", m.miles.deadhead)
        case .orders: return "\(m.completed)"
        case .wait: return m.restaurantWait.averageMinutes.map { String(format: "%.0f min", $0) } ?? "—"
        }
    }

    /// The short label over a bar.
    func bar(_ v: Double) -> String {
        switch self {
        case .earnings, .expenses, .net, .deduction: return "$\(Int(v.rounded()))"
        case .perHour: return "$\(Int(v))"
        case .perMile: return String(format: "$%.2f", v)
        case .hours, .idle, .active: return String(format: "%.1f", v)
        case .miles, .deadhead: return "\(Int(v.rounded()))"
        case .orders: return "\(Int(v))"
        case .wait: return "\(Int(v.rounded()))m"
        }
    }

    /// Money metrics get the accent color (like Gridwise's green earnings bars); the rest are gray.
    var isMoney: Bool { [ChartMetric.earnings, .net, .deduction, .expenses, .perHour, .perMile].contains(self) }

    /// Mileage deduction rate (user, Oct 16, like Gridwise: $0.67 per mile driven); changeable in Account.
    static var deductionCentsPerMile: Int { UserDefaults.standard.object(forKey: "mileageDeductionCents") as? Int ?? 67 }

    /// Miles __APP_NAME__ tracked × your rate, plus Gridwise's own deduction for imported days (its rate changed during the year).
    static func deductionCents(_ m: RangeMetrics) -> Int {
        let tracked = max(0, m.miles.total - (m.miles.imported ?? 0))
        return Int((tracked * Double(deductionCentsPerMile)).rounded()) + (m.importedDeductionCents ?? 0)
    }
}

/// The week's totals as a 2-column grid of tiles; the selected tile is highlighted and drives the chart below.
struct MetricTiles: View {
    let week: RangeMetrics
    @Binding var selection: ChartMetric
    // Like Gridwise (user, Oct 16): earnings, expenses, net, hours, miles, the mileage deduction, orders, deadhead.
    private let metrics: [ChartMetric] = [.earnings, .expenses, .net, .hours, .miles, .deduction, .orders, .deadhead]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<metrics.count / 2, id: \.self) { row in
                HStack(spacing: 0) {
                    tile(metrics[row * 2])
                    Divider()
                    tile(metrics[row * 2 + 1])
                }
                .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
        }
    }

    private func tile(_ metric: ChartMetric) -> some View {
        let selected = selection == metric
        return Button { withAnimation(.easeInOut(duration: 0.2)) { selection = metric } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(selected ? Theme.purple : Color.clear).frame(height: 4)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.tile(week)).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text(subtitle(metric)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: metric.icon).font(.body).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ metric: ChartMetric) -> String {
        switch metric {
        case .orders:
            let lost = week.unassigned + week.cancelled
            return lost > 0 ? "Orders · \(lost) ended early" : "Orders"
        case .hours: return "Hours"
        case .deduction: return String(format: "Deduction · %d¢/mi", ChartMetric.deductionCentsPerMile)
        case .idle: return "Idle hours"
        case .active: return "Hours on deliveries"
        case .deadhead: return "Deadhead miles"
        default: return metric.rawValue
        }
    }
}

/// Mon–Sun bars, always all seven (empty days as short stubs), today marked; tap a bar to select its day.
struct WeekBarChart: View {
    let days: [RangeMetrics]
    let dates: [Date]
    let metric: ChartMetric
    let today: Int?
    @Binding var selected: Int?
    private let height: CGFloat = 130

    var body: some View {
        let values = days.map { metric.value($0) }
        let top = max(values.max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Button { withAnimation(.easeInOut(duration: 0.15)) { selected = selected == index ? nil : index } } label: {
                    VStack(spacing: 6) {
                        Text(value > 0 ? metric.bar(value) : " ").font(.caption.weight(.semibold))
                            .foregroundStyle(selected == nil || selected == index ? Color.primary : Color.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(color(index, empty: value <= 0))
                            .frame(width: 30, height: value > 0 ? max(8, height * CGFloat(value / top)) : 8)
                        Text(letter(index)).font(.footnote.weight(index == today ? .bold : .regular))
                            .foregroundStyle(index == today ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: height + 46, alignment: .bottom)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(dates.indices.contains(index) ? dates[index].formatted(.dateTime.weekday(.wide)) : ""): \(metric.bar(value))")
            }
        }
    }

    private func color(_ index: Int, empty: Bool) -> Color {
        if empty { return Color(.tertiarySystemFill) }
        let base = metric.isMoney ? Theme.purple : Color(.systemGray2)
        return selected == nil || selected == index ? base : base.opacity(0.35)
    }

    private func letter(_ index: Int) -> String {
        guard dates.indices.contains(index) else { return "" }
        return String(dates[index].formatted(.dateTime.weekday(.narrow)))
    }
}

/// The tapped day, in one line under the chart; opens the day.
struct SelectedDayRow: View {
    let day: RangeMetrics
    let date: Date
    var body: some View {
        NavigationLink { DayDetailView(day: day, date: date) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.subheadline.weight(.semibold))
                    Text(day.completed == 0 && day.onlineSeconds == 0 ? "No work this day"
                         : "\(day.completed) order\(day.completed == 1 ? "" : "s") · \(ShiftFormat.duration(day.onlineSeconds)) · \(ShiftFormat.rate(day.perOnlineHourCents, "hr"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ShiftFormat.money(day.earningsCents)).font(.subheadline.weight(.semibold).monospacedDigit())
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Gridwise's "Efficiency" strip: per hour, per active hour, per mile, per order. Per hour and per mile also chart.
/// The week's rates in one line under the chart (polish pass: was a separate "Efficiency" card).
struct RatesLine: View {
    let week: RangeMetrics
    var body: some View {
        Text([ShiftFormat.rate(week.perOnlineHourCents, "hr"), ShiftFormat.rate(week.perActiveHourCents, "hr") + " on orders",
              ShiftFormat.rate(week.perMileCents, "mi")].joined(separator: "  ·  "))
            .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The seven days as rows ("Mon, Oct 12 … $45.95 ›"), each opening the day's shifts and orders.
struct ByDayList: View {
    let stats: WeekStats
    let dates: [Date]
    @ObservedObject private var goals = GoalStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By day").font(.headline).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(stats.days.enumerated()), id: \.offset) { index, day in
                    if dates.indices.contains(index) {
                        NavigationLink { DayDetailView(day: day, date: dates[index]) } label: {
                            HStack {
                                Text(dates[index].formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                Spacer()
                                // A day that reached the daily goal.
                                if let goal = goals.dailyCents, day.earningsCents >= goal {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Daily goal reached")
                                }
                                Text(ShiftFormat.money(day.earningsCents)).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < stats.days.count - 1 { Divider() }
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
