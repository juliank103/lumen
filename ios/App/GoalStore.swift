import SwiftUI

/// Daily and weekly earnings goals (user, Oct 19), next to the per-shift goal in ShiftStore. A day is local midnight to
/// midnight, a week is Monday to Sunday (as on the Earnings page). Progress comes from core/shift.js `goals`, so it counts
/// exactly what Earnings counts: orders, tips and bonuses, and imported Gridwise days.
@MainActor
final class GoalStore: ObservableObject {
    static let shared = GoalStore()

    @Published private(set) var dailyCents: Int?
    @Published private(set) var weeklyCents: Int?

    private init() {
        dailyCents = UserDefaults.standard.object(forKey: "dailyGoalCents") as? Int
        weeklyCents = UserDefaults.standard.object(forKey: "weeklyGoalCents") as? Int
    }

    func set(daily: Int?, weekly: Int?) {
        dailyCents = daily.flatMap { $0 > 0 ? $0 : nil }
        weeklyCents = weekly.flatMap { $0 > 0 ? $0 : nil }
        UserDefaults.standard.set(dailyCents, forKey: "dailyGoalCents")
        UserDefaults.standard.set(weeklyCents, forKey: "weeklyGoalCents")
    }

    var hasAny: Bool { dailyCents != nil || weeklyCents != nil }
}

struct GoalsStatus: Decodable, Equatable {
    struct Status: Decodable, Equatable {
        let goalCents: Int
        let earningsCents: Int
        let progress: Double
        let remainingCents: Int
        let reached: Bool
        /// A day: minutes still needed at today's pace. A week: days left (counting today) and dollars a day to get there.
        let minutesAtPace: Int?
        let daysLeft: Int?
        let perDayCents: Int?
    }
    let daily: Status?
    let weekly: Status?
    let todayCents: Int
    let weekCents: Int

    /// Today and this week, from the phone's calendar (Monday-first, like the Earnings page).
    @MainActor
    static func compute(now: Date = Date()) -> GoalsStatus? {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        let iso = ISO8601DateFormatter()
        let from = week.start.addingTimeInterval(-86_400)
        let trips = (TripStore.shared.history + [TripStore.shared.active].compactMap { $0 })
            .filter { ($0.endedAt ?? now) >= from && $0.startedAt < week.end }
        let shifts = (ShiftStore.shared.history + [ShiftStore.shared.current].compactMap { $0 })
            .filter { ($0.endedAt ?? now) >= from && $0.startedAt < week.end }
        let goals: [String: Any] = ["dailyCents": GoalStore.shared.dailyCents.map { $0 as Any } ?? NSNull(),
                                    "weeklyCents": GoalStore.shared.weeklyCents.map { $0 as Any } ?? NSNull()]
        let input = "{\"shifts\":\(ShiftEngine.json(encodable: shifts)),\"trips\":\(ShiftEngine.json(encodable: trips)),"
            + "\"entries\":\(EntryStore.shared.json),\"goals\":\(ShiftEngine.json(goals)),"
            + "\"day\":\(ShiftEngine.json(["start": iso.string(from: dayStart), "end": iso.string(from: dayEnd)])),"
            + "\"week\":\(ShiftEngine.json(["start": iso.string(from: week.start), "end": iso.string(from: week.end)])),"
            + "\"now\":\(ShiftEngine.json(iso.string(from: now))),\"offsetMinutes\":\(ShiftEngine.offsetMinutes)}"
        return ShiftEngine.decode(GoalsStatus.self, ShiftEngine.call("goalsJSON", [input]))
    }
}

/// Home: today's and this week's progress. One small line to set goals when there are none.
struct GoalsCard: View {
    @ObservedObject private var goals = GoalStore.shared
    @ObservedObject private var shifts = ShiftStore.shared
    @ObservedObject private var trips = TripStore.shared
    @ObservedObject private var entries = EntryStore.shared
    @State private var status: GoalsStatus?
    @State private var editing = false

    var body: some View {
        Group {
            if goals.hasAny, let status {
                VStack(alignment: .leading, spacing: 14) {
                    if let day = status.daily { GoalProgressRow(title: "Today", status: day, weekly: false) }
                    if let week = status.weekly { GoalProgressRow(title: "This week", status: week, weekly: true) }
                }
                .dasherCard()
                .contentShape(Rectangle())
                .onTapGesture { editing = true }
            } else if !goals.hasAny {
                Button("Set daily and weekly goals") { editing = true }.font(.footnote.weight(.semibold))
            }
        }
        .goalEditor(isPresented: $editing)
        // A goal just reached.
        .sensoryFeedback(.success, trigger: (status?.daily?.reached == true ? 1 : 0) + (status?.weekly?.reached == true ? 1 : 0)) { old, new in new > old }
        .onAppear(perform: refresh)
        .onChange(of: goals.dailyCents) { refresh() }
        .onChange(of: goals.weeklyCents) { refresh() }
        .onChange(of: trips.history.count) { refresh() }
        .onChange(of: entries.entries.count) { refresh() }
        .onReceive(shifts.$metrics) { _ in refresh() }
    }

    private func refresh() {
        guard goals.hasAny else { status = nil; return }
        let next = GoalsStatus.compute()
        if next != status { status = next }
    }
}

/// One goal: a bar, what's left, and what it takes.
struct GoalProgressRow: View {
    let title: String
    let status: GoalsStatus.Status
    let weekly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(ShiftFormat.money(status.earningsCents) + " of " + ShiftFormat.money(status.goalCents))
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: status.progress).tint(status.reached ? Color.green : Theme.purple)
            Text(caption).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        if status.reached { return "Goal reached" }
        var text = ShiftFormat.money(status.remainingCents) + " to go"
        if weekly, let days = status.daysLeft, let perDay = status.perDayCents {
            text += " · " + ShiftFormat.money(perDay) + "/day for \(days) day" + (days == 1 ? "" : "s")
        } else if !weekly, let minutes = status.minutesAtPace {
            text += " · about " + ShiftFormat.duration(minutes * 60) + " more at today's pace"
        }
        return text
    }
}

/// The three goals in one place: per shift, per day, per week. Opened from Home, Earnings, and Account.
struct GoalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var goals = GoalStore.shared
    @ObservedObject private var shifts = ShiftStore.shared
    @State private var shift = ""
    @State private var daily = ""
    @State private var weekly = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("Per shift", text: $shift, hint: "e.g. 150")
                    field("Per day", text: $daily, hint: "e.g. 200")
                    field("Per week", text: $weekly, hint: "e.g. 1000")
                } footer: {
                    Text("Empty means no goal. Weeks run Mon–Sun.")
                }
            }
            .navigationTitle("Goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear {
                shift = Self.text(shifts.defaultGoalCents)
                daily = Self.text(goals.dailyCents)
                weekly = Self.text(goals.weeklyCents)
            }
        }
        .presentationDetents([.medium])
    }

    private func field(_ label: String, text: Binding<String>, hint: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("$").foregroundStyle(.secondary)
            TextField(hint, text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 110)
        }
    }

    private func save() {
        shifts.setGoal(Self.cents(shift))
        goals.set(daily: Self.cents(daily), weekly: Self.cents(weekly))
        dismiss()
    }

    private static func text(_ cents: Int?) -> String {
        guard let cents, cents > 0 else { return "" }
        return cents % 100 == 0 ? String(cents / 100) : String(format: "%.2f", Double(cents) / 100)
    }

    private static func cents(_ text: String) -> Int? {
        let clean = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(clean), value > 0 else { return nil }
        return Int((value * 100).rounded())
    }
}

/// Earnings page: the shown week's progress toward the weekly goal (past weeks too: did that week make it).
struct WeekGoalRow: View {
    let week: RangeMetrics
    @Binding var editing: Bool
    @ObservedObject private var goals = GoalStore.shared

    var body: some View {
        if let goal = goals.weeklyCents {
            let progress = min(1, Double(week.earningsCents) / Double(goal))
            let reached = week.earningsCents >= goal
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Weekly goal").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(ShiftFormat.money(week.earningsCents) + " of " + ShiftFormat.money(goal))
                        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: progress).tint(reached ? Color.green : Theme.purple)
                Text(reached ? "Goal reached" : ShiftFormat.money(goal - week.earningsCents) + " short")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .dasherCard()
            .contentShape(Rectangle())
            .onTapGesture { editing = true }
        }
    }
}
