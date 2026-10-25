import SwiftUI

/// One shift on one scrolling page (trim pass, Oct 15: was a summary plus five drill-down pages): earnings and goal,
/// four key numbers, then time, miles, apps, and orders.
struct ShiftOverview: View {
    let shift: Shift
    let metrics: ShiftMetrics
    var editingGoal: Binding<Bool>? = nil
    @ScaledMetric(relativeTo: .largeTitle) private var earningsSize: CGFloat = 44
    /// Optional vehicle cost per mile (Account), for earnings after costs.
    @AppStorage("vehicleCostCentsPerMile") private var costPerMile = 0

    var body: some View {
        let m = metrics
        let cost = Int((Double(costPerMile) * m.miles.total).rounded())
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                CountUpMoney(cents: m.earningsCents, remember: false).font(.system(size: earningsSize, weight: .bold, design: .rounded))
                if costPerMile > 0 {
                    Text(ShiftFormat.money(m.earningsCents - cost) + " after vehicle cost").font(.subheadline).foregroundStyle(.secondary)
                }
                GoalBar(metrics: m, editing: editingGoal ?? .constant(false))
            }
            .padding(.vertical, 6)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                GridRow {
                    KeyMetric(value: ShiftFormat.rate(m.shiftHourlyCents, "hr"), label: "per hour")
                    KeyMetric(value: ShiftFormat.rate(m.perMileCents, "mi"), label: "per mile")
                }
                GridRow {
                    KeyMetric(value: ShiftFormat.duration(m.shiftSeconds), label: "online")
                    KeyMetric(value: "\(m.completed)", label: m.completed == 1 ? "order completed" : "orders completed")
                }
            }
            .padding(.vertical, 8)
        }
        if let deliveries = m.completions, !deliveries.isEmpty {
            // Each delivery on the shift clock (user, Oct 15): when it landed, what it added, and the hourly after it.
            Section {
                ForEach(deliveries, id: \.offerId) { c in
                    HStack(spacing: 10) {
                        AppLogo(platform: c.platform, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.merchant ?? Theme.appName(c.platform)).lineLimit(1)
                            Text(ShiftClock.clock(TimeInterval(c.clockSeconds)) + " · +" + ShiftFormat.money(c.payCents)
                                 + " in " + ShiftFormat.duration(c.sinceLastSeconds))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ShiftFormat.rate(c.hourlyCents, "hr")).monospacedDigit()
                    }
                }
            } header: {
                HStack {
                    Text("Deliveries")
                    InfoNote(title: "Shift clock", text: "Hourly = earnings so far ÷ shift time.")
                }
            }
        }
        Section("Time") {
            row("On deliveries", ShiftFormat.duration(m.activeSeconds) + " · " + ShiftFormat.rate(m.perActiveHourCents, "hr"))
            row("Idle", ShiftFormat.duration(m.idleSeconds))
            if let wait = m.restaurantWait.averageMinutes {
                row("Store wait", String(format: "%.0f min average", wait)
                    + (m.restaurantWait.longestMinutes.map { String(format: ", %.0f longest", $0) } ?? ""))
            }
        }
        Section("Miles") {
            row("Total", ShiftFormat.miles(m.miles.total))
            row("Paid (to the store and delivering)", ShiftFormat.miles(m.miles.order))
            row("Deadhead (driving back and repositioning)", ShiftFormat.miles(m.miles.deadhead))
        }
        if !m.byPlatform.isEmpty {
            Section("Apps") {
                ForEach(["doordash", "uber_eats", "grubhub"], id: \.self) { platform in
                    if let app = m.byPlatform[platform] {
                        HStack(spacing: 10) {
                            AppLogo(platform: platform, size: 22)
                            Text(Theme.appName(platform))
                            Spacer()
                            Text("\(app.completed) · \(ShiftFormat.money(app.earningsCents))").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        if m.unassigned + m.cancelled + m.inProgress > 0 {
            Section("Orders") {
                if m.unassigned > 0 { row("Unassigned", "\(m.unassigned)") }
                if m.cancelled > 0 { row("Cancelled", "\(m.cancelled)") }
                if m.inProgress > 0 { row("In progress", "\(m.inProgress)") }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit().multilineTextAlignment(.trailing) }
    }

    private var title: String {
        let start = shift.startedAt.formatted(date: .omitted, time: .shortened)
        if shift.endedAt == nil { return "This shift · since \(start)" }
        let end = (shift.endedAt ?? shift.startedAt).formatted(date: .omitted, time: .shortened)
        return shift.startedAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) + " · \(start)–\(end)"
    }
}

struct KeyMetric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small ⓘ that shows an explanation on tap (trim pass: explanations moved out of always-visible footers).
struct InfoNote: View {
    let title: String
    let text: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Image(systemName: "info.circle").font(.subheadline) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("About " + title)
            .alert(title, isPresented: $showing) { Button("OK", role: .cancel) {} } message: { Text(text) }
    }
}
