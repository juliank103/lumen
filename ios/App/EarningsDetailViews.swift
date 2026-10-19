import SwiftUI
import Charts

// Earnings drill-downs (split from WeekStatsViews.swift in the polish pass): a day, a past week's recap, and the
// share of earnings by app.

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
    case "uber": return Color(red: 0.25, green: 0.25, blue: 0.28)
    case "instacart": return Color(red: 0.26, green: 0.62, blue: 0.25)
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
                if week.earningsCents == 0 {
                    Text("No earnings yet this week.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
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
