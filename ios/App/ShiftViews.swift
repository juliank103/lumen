import SwiftUI

enum ShiftFormat {
    static func money(_ cents: Int?) -> String {
        guard let cents else { return "—" }
        return (Double(cents) / 100).formatted(.currency(code: "USD"))
    }
    static func rate(_ cents: Int?, _ unit: String) -> String {
        guard let cents else { return "—" }
        return unit == "mi" ? String(format: "$%.2f/mi", Double(cents) / 100) : "$\(cents / 100)/\(unit)"
    }
    static func duration(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }
    static func miles(_ value: Double) -> String { String(format: "%.1f mi", value) }
    static func percent(_ part: Double, _ whole: Double) -> String {
        whole > 0 ? "\(Int((part / whole * 100).rounded()))%" : "—"
    }
}

/// Dash: the running shift in one strip — earnings, pace, and the goal bar. Details live on Stats.
struct ShiftSummaryCard: View {
    @ObservedObject private var shifts = ShiftStore.shared
    @ObservedObject private var trips = TripStore.shared
    @State private var editingGoal = false
    @ScaledMetric(relativeTo: .largeTitle) private var earningsSize: CGFloat = 32

    var body: some View {
        if let shift = shifts.current, let m = shifts.metrics, trips.active != nil {
            // On a trip, one line is enough (trim pass): the trip card is what matters while driving.
            HStack {
                ShiftClock(shift: shift).foregroundStyle(.secondary)
                Spacer()
                Text(ShiftFormat.money(m.earningsCents) + " · " + ShiftFormat.rate(m.shiftHourlyCents, "hr")).monospacedDigit()
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if let shift = shifts.current, let m = shifts.metrics {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.period.map { "\($0.label) shift" } ?? "This shift").font(.subheadline).foregroundStyle(.secondary)
                        Text(ShiftFormat.money(m.earningsCents)).font(.system(size: earningsSize, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        // Earnings ÷ the shift clock at the last delivery (user, Oct 15); "—" until the first one.
                        Text(ShiftFormat.rate(m.shiftHourlyCents, "hr")).font(.title3.weight(.semibold))
                        ShiftClock(shift: shift).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                GoalBar(metrics: m, editing: $editingGoal)
            }
            .dasherCard()
            .goalEditor(isPresented: $editingGoal)
        }
    }
}

/// The running shift timer ("⏱ 1:42:07"), ticking every second; it stops at the pause while reading is paused.
struct ShiftClock: View {
    let shift: Shift
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: shift.pausedAt == nil ? "stopwatch" : "pause.circle")
            if let paused = shift.pausedAt {
                Text(Self.clock(paused.timeIntervalSince(shift.startedAt)))
            } else {
                TimelineView(.periodic(from: shift.startedAt, by: 1)) { context in
                    Text(Self.clock(context.date.timeIntervalSince(shift.startedAt)))
                }
            }
        }
        .monospacedDigit()
        .accessibilityLabel("Shift time")
    }
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// Earnings goal progress and when it should be reached at the pace so far (updates as orders complete).
/// Tap it to change the goal.
struct GoalBar: View {
    let metrics: ShiftMetrics
    @Binding var editing: Bool

    var body: some View {
        if let goal = metrics.goal {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: goal.progress).tint(goal.reached ? Color.green : Theme.purple)
                HStack {
                    Text(goal.reached ? "Goal reached: \(ShiftFormat.money(goal.goalCents))"
                         : "\(ShiftFormat.money(goal.remainingCents)) to \(ShiftFormat.money(goal.goalCents))")
                    Spacer()
                    if let eta = ShiftEngine.date(goal.etaAt) {
                        Text("≈ " + eta.formatted(date: .omitted, time: .shortened))
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = true }
        } else if metrics.live {
            Button("Set an earnings goal") { editing = true }.font(.footnote.weight(.semibold))
        }
    }
}

extension View {
    func goalEditor(isPresented: Binding<Bool>) -> some View { modifier(GoalEditor(isPresented: isPresented)) }
}

private struct GoalEditor: ViewModifier {
    @Binding var isPresented: Bool
    @State private var text = ""

    func body(content: Content) -> some View {
        content.alert("Earnings goal", isPresented: $isPresented) {
            TextField("Dollars, e.g. 200", text: $text).keyboardType(.decimalPad)
            Button("Save") { ShiftStore.shared.setGoal(Double(text.replacingOccurrences(of: "$", with: "")).map { Int(($0 * 100).rounded()) }) }
            Button("No goal", role: .destructive) { ShiftStore.shared.setGoal(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Used for this shift and the next ones.")
        }
        .onChange(of: isPresented) { _, shown in
            if shown { text = ShiftStore.shared.defaultGoalCents.map { String($0 / 100) } ?? "" }
        }
    }
}

struct ShiftHistoryView: View {
    @ObservedObject private var shifts = ShiftStore.shared
    @State private var editing: ShiftEditTarget?
    @State private var deleting: Shift?

    var body: some View {
        List(Array(shifts.history.reversed())) { shift in
            NavigationLink {
                PastShiftView(shiftId: shift.id)
            } label: {
                ShiftRow(shift: shift, metrics: shifts.metrics(for: shift))
            }
            .swipeActions {
                Button(role: .destructive) { deleting = shift } label: { Label("Delete", systemImage: "trash") }
                Button { editing = ShiftEditTarget(shift: shift) } label: { Label("Edit", systemImage: "clock") }.tint(Theme.purple)
            }
        }
        .navigationTitle("Past shifts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = ShiftEditTarget(shift: nil) } label: { Image(systemName: "plus") }.accessibilityLabel("Add a shift")
            }
        }
        .sheet(item: $editing) { target in ShiftEditor(shift: target.shift) }
        .confirmationDialog("Delete this shift?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { shift in
            Button("Delete shift", role: .destructive) { shifts.deleteShift(shift.id) }
        } message: { _ in
            Text("Its time and miles are removed from your stats. Orders from that time stay in Offers.")
        }
        .overlay {
            if shifts.history.isEmpty { ContentUnavailableView("No past shifts yet", systemImage: "clock") }
        }
    }
}

/// One past shift, with "Edit times" in the toolbar.
struct PastShiftView: View {
    @ObservedObject private var shifts = ShiftStore.shared
    let shiftId: String
    @State private var editing = false

    var body: some View {
        if let shift = (shifts.history + [shifts.current].compactMap { $0 }).first(where: { $0.id == shiftId }) {
            List {
                if let m = shifts.metrics(for: shift) { ShiftOverview(shift: shift, metrics: m) }
            }
            .navigationTitle(shift.startedAt.formatted(date: .abbreviated, time: .omitted))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit times") { editing = true } } }
            .sheet(isPresented: $editing) { ShiftEditor(shift: shift) }
        } else {
            ContentUnavailableView("Shift deleted", systemImage: "clock")
        }
    }
}

struct ShiftEditTarget: Identifiable {
    let id = UUID()
    let shift: Shift?
}

/// Edit a shift's hours, delete it, or add one worked without Lumen running (shift nil). The running shift's start
/// can be moved; it ends by itself or with End shift.
struct ShiftEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var shifts = ShiftStore.shared
    let shift: Shift?
    @State private var start = Date()
    @State private var end = Date()
    @State private var confirmDelete = false

    private var isRunning: Bool { shift != nil && shift?.id == shifts.current?.id }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Started", selection: $start, in: ...Date())
                    if !isRunning {
                        DatePicker("Ended", selection: $end, in: start...Date())
                    }
                } footer: {
                    Text(isRunning ? "The shift is still running; it ends by itself or with End shift."
                         : "Online time: " + ShiftFormat.duration(Int(max(0, end.timeIntervalSince(start)))) + ". Miles aren't changed.")
                }
                if shift != nil && !isRunning {
                    Section {
                        Button("Delete shift", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(shift == nil ? "Add a shift" : "Edit shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let shift { shifts.updateShift(shift.id, start: start, end: isRunning ? nil : end) }
                        else { shifts.addShift(start: start, end: end) }
                        dismiss()
                    }
                    .disabled(!isRunning && end <= start)
                }
            }
            .confirmationDialog("Delete this shift?", isPresented: $confirmDelete) {
                Button("Delete shift", role: .destructive) {
                    if let shift { shifts.deleteShift(shift.id) }
                    dismiss()
                }
            }
            .onAppear {
                if let shift {
                    start = shift.startedAt
                    end = shift.endedAt ?? Date()
                } else {
                    end = Date()
                    start = end.addingTimeInterval(-4 * 3600)
                }
            }
        }
    }
}

struct ShiftRow: View {
    let shift: Shift
    let metrics: ShiftMetrics?
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(shift.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                     + (metrics?.period.map { " · \($0.label)" } ?? "")).font(.headline)
                if let m = metrics {
                    Text("\(ShiftFormat.duration(m.shiftSeconds)) · \(ShiftFormat.rate(m.perOnlineHourCents, "hr")) · \(m.completed) orders")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let m = metrics { Text(ShiftFormat.money(m.earningsCents)).font(.headline.monospacedDigit()) }
        }
    }
}
