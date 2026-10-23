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
}

/// Shift planner (user, Oct 23): "To make $1,000 this week, work these hours." The best hours left in the week from your
/// own $/hr at each weekday and hour, until they cover what's left of the target. The target starts at the weekly goal.
struct PlannerView: View {
    @ObservedObject private var goals = GoalStore.shared
    @State private var targetText = ""
    @State private var plan: ShiftPlan?
    @FocusState private var editing: Bool

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
            + "\"entries\":\(EntryStore.shared.json),\"targetCents\":\(targetCents ?? 0),"
            + "\"week\":\(ShiftEngine.json(["start": iso.string(from: week.start), "end": iso.string(from: week.end)])),"
            + "\"now\":\(ShiftEngine.json(iso.string(from: now))),\"offsetMinutes\":\(ShiftEngine.offsetMinutes)}"
        let result = ShiftEngine.decode(ShiftPlan.self, ShiftEngine.call("shiftPlanJSON", [input]))
        if result != plan { plan = result }
    }
}
