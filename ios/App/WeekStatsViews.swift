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
                        EfficiencyStrip(week: stats.week, selection: $metric)
                        ByDayList(stats: stats, dates: week.days)
                        AppShareList(week: stats.week)
                        if let first = week.days.first, let end = Calendar.current.date(byAdding: .day, value: 7, to: first) {
                            AccuracyCard(from: first, to: end)
                        }
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
                            Button("End shift", role: .destructive) { confirmEnd = true }
                            Button("Edit shift times…") { editingShift = ShiftEditTarget(shift: current) }
                        } else {
                            Button("Start shift") { shifts.startIfNeeded() }
                            if let last = shifts.history.last {
                                Button("Edit last shift's times…") { editingShift = ShiftEditTarget(shift: last) }
                            }
                        }
                        Button("Add a past shift…") { editingShift = ShiftEditTarget(shift: nil) }
                        Button("Earnings goal…") { editingGoal = true }
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
        case .deduction: return m.miles.total * Double(Self.deductionCentsPerMile) / 100
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
        case .deduction: return ShiftFormat.money(Int((m.miles.total * Double(Self.deductionCentsPerMile)).rounded()))
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
struct EfficiencyStrip: View {
    let week: RangeMetrics
    @Binding var selection: ChartMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Efficiency").font(.headline).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                cell(ShiftFormat.rate(week.perOnlineHourCents, "hr"), "Per hour", .perHour)
                cell(ShiftFormat.rate(week.perActiveHourCents, "hr"), "Per active hr", nil)
                cell(ShiftFormat.rate(week.perMileCents, "mi"), "Per mile", .perMile)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder private func cell(_ value: String, _ label: String, _ metric: ChartMetric?) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(metric != nil && selection == metric ? Theme.purple : Color.primary)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let metric {
            Button { withAnimation { selection = metric } } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// The seven days as rows ("Mon, Oct 12 … $45.95 ›"), each opening the day's shifts and orders.
struct ByDayList: View {
    let stats: WeekStats
    let dates: [Date]

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

// MARK: Day

struct DayDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var shifts = ShiftStore.shared
    let day: RangeMetrics
    let date: Date
    @State private var deleting: RangeMetrics.OrderRow?
    @State private var editing: ShiftEditTarget?
    @State private var editingOrder: OrderEditTarget?

    var body: some View {
        List {
            Section {
                row("Earnings", ShiftFormat.money(day.earningsCents))
                row("Per online hour", ShiftFormat.rate(day.perOnlineHourCents, "hr"))
                row("Per active hour", ShiftFormat.rate(day.perActiveHourCents, "hr"))
                row("Per mile", ShiftFormat.rate(day.perMileCents, "mi"))
            }
            Section("Time and miles") {
                row("Online", ShiftFormat.duration(day.onlineSeconds))
                row("On deliveries", ShiftFormat.duration(day.activeSeconds))
                row("Idle", ShiftFormat.duration(day.idleSeconds))
                row("Miles", ShiftFormat.miles(day.miles.total))
                row("Deadhead", ShiftFormat.miles(day.miles.deadhead))
                row("Average store wait", day.restaurantWait.averageMinutes.map { String(format: "%.0f min", $0) } ?? "—")
            }
            if let platforms = day.platforms, !platforms.isEmpty {
                Section("Platforms") {
                    ForEach(platforms) { p in
                        HStack(spacing: 10) {
                            AppLogo(platform: p.key, size: 22)
                            Text(Theme.appName(p.key))
                            Spacer()
                            Text("\(ShiftFormat.money(p.earningsCents)) · \(ShiftFormat.rate(p.perHourCents, "hr"))").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let refs = day.shifts, !refs.isEmpty {
                Section("Shifts") {
                    ForEach(refs) { ref in
                        let shift = (shifts.history + [shifts.current].compactMap { $0 }).first { $0.id == ref.id }
                        NavigationLink {
                            PastShiftView(shiftId: ref.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((ref.period?.label ?? "") + (ref.period == nil ? "Shift" : " shift"))
                                Text(timeRange(ref.startedAt, ref.endedAt)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if let shift { Button { editing = ShiftEditTarget(shift: shift) } label: { Label("Edit", systemImage: "clock") }.tint(Theme.purple) }
                        }
                    }
                }
            }
            if let entries = day.entries, !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.kind == "expense" ? "minus.circle.fill" : "plus.circle.fill")
                                .foregroundStyle(entry.kind == "expense" ? Color.red : Color.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.category ?? (entry.kind == "expense" ? "Expense" : "Earnings"))
                                Text([entry.platform.map(Theme.appName), entry.note].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text((entry.kind == "expense" ? "−" : "+") + ShiftFormat.money(entry.amountCents)).monospacedDigit()
                        }
                        .swipeActions {
                            Button(role: .destructive) { EntryStore.shared.delete(entry.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("Added")
                } footer: {
                    if let net = day.netCents, (day.expensesCents ?? 0) > 0 { Text("Net after expenses: " + ShiftFormat.money(net)) }
                }
            }
            if let orders = day.orders, !orders.isEmpty {
                Section("Orders") {
                    ForEach(orders) { order in
                        let offer = model.offers.first { ($0.offerId ?? $0.id) == order.offerId }
                        NavigationLink {
                            if let offer { OfferDetail(offer: offer) } else { Text("This offer is no longer stored.") }
                        } label: {
                            DayOrderRow(order: order)
                        }
                        .swipeActions {
                            Button(role: .destructive) { deleting = order } label: { Label("Delete", systemImage: "trash") }
                            Button { editingOrder = OrderEditTarget(offerId: order.offerId) } label: { Label("Edit", systemImage: "pencil") }
                                .tint(Theme.purple)
                        }
                    }
                }
            }
            Section {
                row("Completed", "\(day.completed)")
                row("Unassigned", "\(day.unassigned)")
                row("Cancelled", "\(day.cancelled)")
            }
        }
        .navigationTitle(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { target in ShiftEditor(shift: target.shift) }
        .sheet(item: $editingOrder) { target in OrderEditor(offerId: target.offerId) }
        .confirmationDialog("Delete this order?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { order in
            Button("Delete from history", role: .destructive) { model.deleteOffer(order.offerId) }
        } message: { _ in
            Text("Its times, pay, and store waits are removed from your history and stats. Go back to see the totals update.")
        }
    }

    private func timeRange(_ start: String, _ end: String?) -> String {
        let a = ShiftEngine.date(start)?.formatted(date: .omitted, time: .shortened) ?? "?"
        let b = end.flatMap { ShiftEngine.date($0) }?.formatted(date: .omitted, time: .shortened) ?? "now"
        return "\(a) – \(b)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
    }
}

struct DayOrderRow: View {
    let order: RangeMetrics.OrderRow
    var body: some View {
        HStack(spacing: 12) {
            AppLogo(platform: order.platform, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(order.stores.joined(separator: " + ")).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(outcome).font(.caption).foregroundStyle(order.ended == "completed" ? Color.green : order.ended == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            Text(ShiftFormat.money(order.payCents)).font(.subheadline.monospacedDigit())
        }
    }

    private var outcome: String {
        let time = (ShiftEngine.date(order.acceptedAt)?.formatted(date: .omitted, time: .shortened) ?? "")
        guard let ended = order.ended else { return time + " · in progress" }
        let minutes = order.minutes.map { " · \(Int($0.rounded())) min" } ?? ""
        let pace = order.perHourCents.map { " · " + ShiftFormat.rate($0, "hr") } ?? ""
        return time + " · " + (ended == "completed" ? "completed" : ended) + minutes + pace + (order.stacked ? " · stacked" : "")
    }
}

// MARK: Weekly recap (past weeks)

/// Gridwise-style recap: how the week compared with the one before, its best day, and what did best.
struct WeeklyRecapView: View {
    let stats: WeekStats
    let dates: [Date]
    let title: String

    var body: some View {
        List {
            Section {
                row("Earnings", ShiftFormat.money(stats.week.earningsCents))
                row("Per hour", ShiftFormat.rate(stats.week.perOnlineHourCents, "hr"))
                row("Per mile", ShiftFormat.rate(stats.week.perMileCents, "mi"))
                row("Orders", "\(stats.week.completed)")
            }
            if let c = stats.comparison {
                Section("Vs. the week before") {
                    change("Earnings", c.earnings, true)
                    change("Per hour", c.perOnlineHour, true)
                    change("Per mile", c.perMile, true)
                    change("Deadhead", c.deadhead, false)
                    change("Idle time", c.idle, false)
                    change("Store wait", c.storeWait, false)
                }
            }
            Section("Highlights") {
                if let best = stats.days.indices.max(by: { stats.days[$0].earningsCents < stats.days[$1].earningsCents }),
                   stats.days[best].earningsCents > 0, dates.indices.contains(best) {
                    row("Best day", dates[best].formatted(.dateTime.weekday(.wide)) + " · " + ShiftFormat.money(stats.days[best].earningsCents))
                }
                if let top = stats.lenses.platform.max(by: { ($0.perHourCents ?? 0) < ($1.perHourCents ?? 0) }) {
                    row("Best-paying app", Theme.appName(top.key) + " · " + ShiftFormat.rate(top.perHourCents, "hr"))
                }
                if let top = stats.lenses.restaurant.first(where: { $0.orders >= 2 }) {
                    row("Top restaurant", top.label + " · " + ShiftFormat.money(top.earningsCents))
                }
                if let hour = stats.lenses.hour.max(by: { ($0.perHourCents ?? 0) < ($1.perHourCents ?? 0) }), hour.perHourCents != nil {
                    row("Best hour to start orders", hour.label + " · " + ShiftFormat.rate(hour.perHourCents, "hr"))
                }
            }
        }
        .navigationTitle("Weekly recap")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func change(_ label: String, _ value: Int?, _ higherIsBetter: Bool) -> some View {
        if let value {
            let good = value == 0 ? nil : (value > 0) == higherIsBetter
            HStack {
                Text(label)
                Spacer()
                Text((value > 0 ? "+" : "") + "\(value)%").monospacedDigit()
                    .foregroundStyle(good == nil ? Color.secondary : good! ? Color.green : Color.orange)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}

// MARK: How Lumen did

/// The scorecard (review: trust): did offers Lumen called "Accept" pay better than the others you took, and how far
/// off were its trip-time estimates? From the week's completed orders and the verdicts on their offers.
struct AccuracyCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var trips = TripStore.shared
    let from: Date
    let to: Date

    var body: some View {
        let orders = (trips.history + [trips.active].compactMap { $0 }).flatMap(\.orders)
            .filter { $0.completed && $0.acceptedAt >= from && $0.acceptedAt < to }
        if !orders.isEmpty {
            let verdicts = Dictionary(model.offers.map { ($0.offerId ?? $0.id, Verdict(notice: $0.notice)) }, uniquingKeysWith: { a, _ in a })
            let accepted = orders.filter { verdicts[$0.offerId] == .accept }
            let others = orders.filter { verdicts[$0.offerId] != .accept }
            let errors = orders.compactMap { o -> Double? in
                guard let predicted = o.predictedTripMinutes, let actual = o.minutes else { return nil }
                return abs(actual - Double(predicted))
            }.sorted()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("How Lumen did").font(.headline).foregroundStyle(.secondary)
                    InfoNote(title: "How Lumen did", text: "Pace includes the predicted drive back. Trip-time estimates compare the predicted time to deliver with the time from accepting to delivering.")
                }
                VStack(alignment: .leading, spacing: 10) {
                    row("Offers it said Accept", pace(accepted), accepted.count)
                    row("Other offers you took", pace(others), others.count)
                    if !errors.isEmpty {
                        HStack {
                            Text("Trip-time estimates")
                            Spacer()
                            Text("off by ~\(Int(errors[errors.count / 2].rounded())) min").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func pace(_ orders: [Trip.Order]) -> Int? {
        let paces = orders.compactMap { $0.paceWithReturnCents ?? $0.paceCents }
        return paces.isEmpty ? nil : paces.reduce(0, +) / paces.count
    }

    private func row(_ label: String, _ pace: Int?, _ count: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(count == 0 ? "none" : "\(ShiftFormat.rate(pace, "hr")) · \(count) order\(count == 1 ? "" : "s")").foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

// MARK: Lenses

enum LensKind: String, CaseIterable, Identifiable {
    case platform = "App", area = "Area", restaurant = "Store", period = "Period"
    var id: String { rawValue }
}

/// The same week, regrouped by platform, area, restaurant, or hour of acceptance.
struct LensCard: View {
    let stats: WeekStats
    @State private var kind = LensKind.platform
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Breakdown").font(.headline).foregroundStyle(.secondary)
                InfoNote(title: "Breakdown", text: "$/hr for a group = pay ÷ time from accepting to completing those orders. Period is when the order was accepted: Breakfast 6–11 AM, Lunch 11–3:30, Dinner 3:30–10:30 PM, Late night 10:30–1:30, Early morning 1:30–6 AM. Area uses the drop-off town on the offer card, which mostly Uber Eats shows.")
            }
            VStack(alignment: .leading, spacing: 12) {
                Picker("Group by", selection: $kind) {
                    ForEach(kinds) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                let rows = lensRows
                if rows.isEmpty {
                    Text("No completed orders this week.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(showAll ? rows : Array(rows.prefix(6))) { row in
                    HStack(spacing: 10) {
                        if kind == .platform { AppLogo(platform: row.key, size: 26) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind == .platform ? Theme.appName(row.label) : row.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(row.orders) order\(row.orders == 1 ? "" : "s") · \(ShiftFormat.money(row.earningsCents))"
                                 + (row.waitMinutes.map { String(format: " · %.0fm wait", $0) } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ShiftFormat.rate(row.perHourCents, "hr")).font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .padding(.vertical, 2)
                }
                if rows.count > 6 {
                    Button(showAll ? "Show fewer" : "Show all \(rows.count)") { showAll.toggle() }.font(.subheadline)
                }
            }
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// Area is offered only when at least half the week's orders have a drop-off town (mostly Uber Eats shows one).
    private var kinds: [LensKind] {
        let area = stats.lenses.area
        let known = area.filter { $0.key != "Not shown on the card" }.reduce(0) { $0 + $1.orders }
        let total = area.reduce(0) { $0 + $1.orders }
        return LensKind.allCases.filter { $0 != .area || (total > 0 && known * 2 >= total) }
    }

    private var lensRows: [LensRow] {
        switch kind {
        case .platform: return stats.lenses.platform
        case .area: return stats.lenses.area
        case .restaurant: return stats.lenses.restaurant
        case .period: return stats.lenses.period
        }
    }
}

// MARK: Share by app (user, Oct 16: like Gridwise's "By Work" — a percentage breakdown by app instead of hourly lenses)

private struct AppShare: Identifiable {
    let platform: String
    let cents: Int
    let orders: Int
    let share: Double
    var id: String { platform }
}

private func appShares(_ week: RangeMetrics) -> [AppShare] {
    let total = max(1, week.byPlatform.values.reduce(0) { $0 + $1.earningsCents })
    let known = ["doordash", "uber_eats", "grubhub"]
    let keys = known + week.byPlatform.keys.filter { !known.contains($0) }.sorted()
    return keys.map { key in
        let app = week.byPlatform[key]
        return AppShare(platform: key, cents: app?.earningsCents ?? 0, orders: app?.completed ?? 0,
                        share: Double(app?.earningsCents ?? 0) / Double(total))
    }
}

func appColor(_ platform: String) -> Color {
    switch platform {
    case "doordash": return Color(red: 1.0, green: 0.19, blue: 0.03)
    case "uber_eats": return Color(red: 0.02, green: 0.76, blue: 0.40)
    case "grubhub": return Color(red: 1.0, green: 0.50, blue: 0.0)
    default: return .gray
    }
}

/// The week's earnings as a ring, one color per app.
struct AppShareDonut: View {
    let week: RangeMetrics
    var body: some View {
        let shares = appShares(week).filter { $0.cents > 0 }
        ZStack {
            if shares.isEmpty {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 18).frame(width: 150, height: 150)
            } else {
                Chart(shares) { share in
                    SectorMark(angle: .value("Earnings", share.cents), innerRadius: .ratio(0.8), angularInset: 1.5)
                        .foregroundStyle(appColor(share.platform))
                }
                .chartLegend(.hidden)
            }
            VStack(spacing: 2) {
                Text(ShiftFormat.money(week.earningsCents)).font(.title3.weight(.semibold)).monospacedDigit()
                Text("\(week.completed) order\(week.completed == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(height: 180)
        .padding(.bottom, 4)
    }
}

/// Each app's share of the week's earnings, its dollars, and its orders.
struct AppShareList: View {
    let week: RangeMetrics
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By app").font(.headline).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                let shares = appShares(week)
                ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(appColor(share.platform)).frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Theme.appName(share.platform))
                            Text("\(share.orders) order\(share.orders == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int((share.share * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                        Text("·").foregroundStyle(.secondary)
                        Text(ShiftFormat.money(share.cents)).font(.body.weight(.semibold)).monospacedDigit()
                    }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    if index < shares.count - 1 { Divider().padding(.leading, 44) }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
