import SwiftUI

/// The shift planner's result (core/shift.js `shiftPlan`).
struct ShiftPlan: Decodable, Equatable {
    struct Block: Decodable, Equatable {
        /// ISO times with milliseconds, as JavaScript writes them (ShiftEngine's decoder has no date strategy).
        let start: String, end: String
        let hours: Int, expectedCents: Int, hourlyCents: Int
        var from: Date { Self.parse(start) }
        var to: Date { Self.parse(end) }
        private static func parse(_ text: String) -> Date {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? .distantPast
        }
    }
    let targetCents: Int?
    let earnedCents: Int
    let remainingCents: Int?
    let hours: Int
    let expectedCents: Int
    let reachable: Bool
    let historyHours: Double
    let overallHourlyCents: Int?
    let blocks: [Block]
    /// Hours left out because you said you won't work then.
    let blockedHours: Int?
}

/// Shift planner (user, Oct 23): "To make $1,000 this week, work these hours." The best hours left in the week from your
/// own $/hr at each weekday and hour, until they cover what's left of the target. The target is the weekly goal and is
/// saved as it (user, Oct 26: "set a target to make this week that saves"); days and shifts you won't work are skipped,
/// every week until changed.
struct PlannerView: View {
    @ObservedObject private var goals = GoalStore.shared
    @State private var targetText = ""
    @State private var plan: ShiftPlan?
    @FocusState private var editing: Bool
    /// Shifts you won't work, as "mon:dinner" keys (core/shift.js `shiftPlan` input `blocked`).
    @AppStorage("plannerBlocked") private var blockedText = ""

    private static let days = [("mon", "Mon"), ("tue", "Tue"), ("wed", "Wed"), ("thu", "Thu"), ("fri", "Fri"), ("sat", "Sat"), ("sun", "Sun")]
    private static let parts = [("breakfast", "Breakfast"), ("lunch", "Lunch"), ("dinner", "Dinner"), ("late_night", "Late")]
    private var blocked: Set<String> { Set(blockedText.split(separator: ",").map(String.init)) }

    private var targetCents: Int? {
        Double(targetText.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")).map { Int(($0 * 100).rounded()) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Make this week")
                        Spacer()
                        TextField("$1,000", text: $targetText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .font(.title3.weight(.bold)).frame(maxWidth: 140).focused($editing)
                    }
                    if let plan, let remaining = plan.remainingCents {
                        HStack {
                            stat(TripFormat.dollars(plan.earnedCents), "earned so far")
                            stat(TripFormat.dollars(remaining), "to go")
                        }
                    }
                }
                if let plan { result(plan) }
                daysOff
            }
            .navigationTitle("Shift planner")
            .navigationBarTitleDisplayMode(.inline)
            .menuButton()
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } } }
        }
        .onAppear {
            if targetText.isEmpty { targetText = String((goals.weeklyCents ?? 100_000) / 100) }
            recompute()
        }
        .onChange(of: targetText) { recompute() }
        // Saved as the weekly goal when you finish typing (and when leaving), so Goals and the planner agree.
        .onChange(of: editing) { _, now in if !now { saveTarget() } }
        .onDisappear(perform: saveTarget)
    }

    private func saveTarget() {
        let cents = targetCents.flatMap { $0 > 0 ? $0 : nil }
        if cents != goals.weeklyCents { goals.set(daily: goals.dailyCents, weekly: cents) }
    }

    /// Days and shifts you won't work: tap a box for that shift, a day for the whole day, a shift name for every day.
    private var daysOff: some View {
        Section {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(Self.parts, id: \.0) { part in
                        Button(part.1) { toggle(Self.days.map { $0.0 + ":" + part.0 }) }
                            .font(.caption.weight(.semibold)).buttonStyle(.borderless).frame(maxWidth: .infinity)
                    }
                }
                ForEach(Self.days, id: \.0) { day in
                    GridRow {
                        Button(day.1) { toggle(Self.parts.map { day.0 + ":" + $0.0 }) }
                            .font(.subheadline.weight(.semibold)).buttonStyle(.borderless).frame(width: 44, alignment: .leading)
                        ForEach(Self.parts, id: \.0) { part in cell(day.0 + ":" + part.0) }
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("When you won't work")
        } footer: {
            Text("Tap a box to skip that shift, a day to skip the whole day, or a shift name to skip it every day. Kept every week until you change it. Late runs to 6 AM.")
        }
    }

    private func cell(_ key: String) -> some View {
        let off = blocked.contains(key)
        return Button { toggle([key]) } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(off ? Color.gray.opacity(0.18) : Theme.neonGreen.opacity(0.22))
                .frame(height: 32)
                .overlay(Image(systemName: off ? "xmark" : "checkmark").font(.caption.weight(.bold))
                    .foregroundStyle(off ? Theme.secondaryText : Theme.neonGreen))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(key.replacingOccurrences(of: ":", with: " ") + (off ? ", off" : ", working"))
    }

    /// All of `keys` off, or all back on if they already were.
    private func toggle(_ keys: [String]) {
        var set = blocked
        if keys.allSatisfy(set.contains) { set.subtract(keys) } else { set.formUnion(keys) }
        blockedText = set.sorted().joined(separator: ",")
        recompute()
    }

    @ViewBuilder private func result(_ plan: ShiftPlan) -> some View {
        if plan.overallHourlyCents == nil {
            Section { Text("Drive a few shifts first. The plan comes from your own $/hr at each hour.").foregroundStyle(Theme.secondaryText) }
        } else if plan.remainingCents == 0 {
            Section { Label("Goal reached this week.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.neonGreen) }
        } else {
            Section {
                ForEach(Array(plan.blocks.enumerated()), id: \.offset) { _, block in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(block.from.formatted(.dateTime.weekday(.wide))).font(.headline)
                            Text(block.from.formatted(.dateTime.hour()) + " – " + block.to.formatted(.dateTime.hour()))
                                .font(.subheadline).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("~" + TripFormat.dollars(block.expectedCents)).font(.headline.monospacedDigit())
                            Text(TripFormat.hourly(block.hourlyCents)).font(.subheadline).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("\(plan.hours) h · about \(TripFormat.dollars(plan.expectedCents))")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !plan.reachable {
                        Text("Your usual hours left this week make about \(TripFormat.dollars(plan.expectedCents)), short of the target.")
                            .foregroundStyle(Theme.neonYellow)
                    }
                    if let skipped = plan.blockedHours, skipped > 0 {
                        Text("Skipping \(skipped) h you won't work.")
                    }
                    Text("From your $/hr at each hour, \(String(format: "%.0f", plan.historyHours)) h of history. Hours you've never driven aren't suggested.")
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 24, weight: .heavy, design: .rounded))
            Text(label).font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recompute() {
        var calendar = Calendar.current
        calendar.firstWeekday = 2   // Monday to Sunday, like Earnings and goals.
        let now = Date()
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return }
        let iso = ISO8601DateFormatter()
        let trips = (TripStore.shared.history + [TripStore.shared.active].compactMap { $0 }).filter { !DemoData.isDemo($0.id) }
        let shifts = (ShiftStore.shared.history + [ShiftStore.shared.current].compactMap { $0 }).filter { !DemoData.isDemo($0.id) }
        let input = "{\"shifts\":\(ShiftEngine.json(encodable: shifts)),\"trips\":\(ShiftEngine.json(encodable: trips)),"
            + "\"entries\":\(EntryStore.shared.json),\"targetCents\":\(targetCents ?? 0),\"blocked\":\(ShiftEngine.json(blocked.sorted())),"
            + "\"week\":\(ShiftEngine.json(["start": iso.string(from: week.start), "end": iso.string(from: week.end)])),"
            + "\"now\":\(ShiftEngine.json(iso.string(from: now))),\"offsetMinutes\":\(ShiftEngine.offsetMinutes)}"
        let result = ShiftEngine.decode(ShiftPlan.self, ShiftEngine.call("shiftPlanJSON", [input]))
        if result != plan { plan = result }
    }
}
