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
    @State private var confirmEnd = false
    @ScaledMetric(relativeTo: .largeTitle) private var earningsSize: CGFloat = 32

    var body: some View {
        if let shift = shifts.current, let m = shifts.metrics, trips.active != nil {
            // On a trip, one line is enough (trim pass): the trip card is what matters while driving.
            HStack {
                ShiftClock(shift: shift).foregroundStyle(.secondary)
                // Running shift miles next to the time (user, Oct 18).
                Text(ShiftFormat.miles(m.miles.total)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(ShiftFormat.money(m.earningsCents) + " · " + ShiftFormat.rate(m.shiftHourlyCents, "hr")).monospacedDigit()
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                        Text(ShiftFormat.miles(m.miles.total)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                GoalBar(metrics: m, editing: $editingGoal)
                // Ending a shift lives on Home (user, Oct 16), next to the shift it ends.
                Button(role: .destructive) { confirmEnd = true } label: {
                    Text("End shift").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .dasherCard()
            .goalEditor(isPresented: $editingGoal)
            .confirmationDialog("End this shift?", isPresented: $confirmEnd) {
                Button("End shift", role: .destructive) { shifts.end() }
            } message: {
                Text("Its time and miles stop counting. Screen reading stays on until you stop it.")
            }
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

/// Per-shift, daily, and weekly goals in one sheet (GoalsSheet in GoalStore.swift).
private struct GoalEditor: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) { GoalsSheet() }
    }
}

/// One past shift (from Earnings -> day), with "Edit" in the toolbar.
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } } }
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

/// Edit a shift's hours, delete it, or add one worked without __APP_NAME__ running (shift nil). The running shift's start
/// can be moved; it ends by itself or with End shift.
struct ShiftEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var shifts = ShiftStore.shared
    let shift: Shift?
    /// The day picked in the ＋ sheet, for a new shift.
    var day: Date? = nil
    /// Inside the ＋ sheet's navigation (no own NavigationStack); `onDone` closes the sheet.
    var embedded = false
    var onDone: (() -> Void)? = nil
    @State private var start = Date()
    @State private var end = Date()
    @State private var confirmDelete = false
    /// Running shift: it already ended at `end` (user, Oct 15: "edit the time a shift ended").
    @State private var endRunning = false
    @State private var orderMilesText = ""
    @State private var otherMilesText = ""
    @State private var initialOrderMiles = ""
    @State private var initialOtherMiles = ""

    private var isRunning: Bool { shift != nil && shift?.id == shifts.current?.id }

    var body: some View {
        if embedded { form } else { NavigationStack { form } }
    }

    private func close() { if let onDone { onDone() } else { dismiss() } }

    private func miles(_ text: String) -> Double {
        max(0, Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0)
    }

    private var form: some View {
            Form {
                Section {
                    DatePicker("Started", selection: $start, in: ...Date())
                    if isRunning {
                        Toggle("It already ended", isOn: $endRunning)
                    }
                    if !isRunning || endRunning {
                        DatePicker("Ended", selection: $end, in: start...Date())
                    }
                } footer: {
                    Text(isRunning && !endRunning ? "Still running."
                         : "Online time: " + ShiftFormat.duration(Int(max(0, end.timeIntervalSince(start)))) + ".")
                }
                if !isRunning {
                    Section {
                        HStack {
                            Text("Miles on orders")
                            Spacer()
                            TextField("0", text: $orderMilesText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
                        }
                        HStack {
                            Text("Other miles")
                            Spacer()
                            TextField("0", text: $otherMilesText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
                        }
                    } footer: {
                        Text("Drive-back and repositioning miles.")
                    }
                }
                if shift != nil && !isRunning {
                    Section {
                        Button("Delete shift", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(shift == nil ? "Add miles and time" : "Edit shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let shift {
                            shifts.updateShift(shift.id, start: start, end: isRunning ? nil : end)
                            if isRunning && endRunning { shifts.end(at: end, exact: true) }
                            if !isRunning, orderMilesText != initialOrderMiles || otherMilesText != initialOtherMiles {
                                shifts.setMiles(shift.id, orderMiles: miles(orderMilesText), otherMiles: miles(otherMilesText))
                            }
                        } else {
                            shifts.addShift(start: start, end: end, orderMiles: miles(orderMilesText), otherMiles: miles(otherMilesText))
                        }
                        close()
                    }
                    .disabled((!isRunning || endRunning) && end <= start)
                }
            }
            .confirmationDialog("Delete this shift?", isPresented: $confirmDelete) {
                Button("Delete shift", role: .destructive) {
                    if let shift { shifts.deleteShift(shift.id) }
                    close()
                }
            }
            .onAppear {
                if let shift {
                    start = shift.startedAt
                    end = shift.endedAt ?? Date()
                    let m = shift.meters, mile = 1609.344
                    orderMilesText = String(format: "%.1f", ((m["toPickup"] ?? 0) + (m["delivery"] ?? 0)) / mile)
                    otherMilesText = String(format: "%.1f", ((m["driveBack"] ?? 0) + (m["reposition"] ?? 0)) / mile)
                    initialOrderMiles = orderMilesText
                    initialOtherMiles = otherMilesText
                } else if let day, !Calendar.current.isDateInToday(day) {
                    start = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: day) ?? day
                    end = start.addingTimeInterval(4 * 3600)
                } else {
                    end = Date()
                    start = end.addingTimeInterval(-4 * 3600)
                }
            }
    }
}
