import SwiftUI

// MARK: The ＋ sheet (user, Oct 15: "This is how Gridwise does their + button … I want this")

/// What the ＋ sheet adds: an order (also an offer __APP_NAME__ missed), a shift's miles and time, an expense, or tips,
/// bonuses, and other earnings. Like Gridwise: pick a tile, pick the day on a calendar, then fill in the form.
enum AddKind: String, Hashable, CaseIterable {
    case order, shift, expense, extra
    var title: String {
        switch self {
        case .order: return "Order"
        case .shift: return "Miles and time"
        case .expense: return "Expenses"
        case .extra: return "Tips, bonuses, and other earnings"
        }
    }
}

private enum AddStep: Hashable {
    case day(AddKind)
    case form(AddKind, Date)
}

/// The ＋ that opens the sheet, for the Dash, Offers, and Earnings toolbars.
struct AddButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Image(systemName: "plus") }
            .accessibilityLabel("Add")
            .sheet(isPresented: $showing) { AddSheet().environmentObject(model) }
    }
}

struct AddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AddStep] = []
    @State private var detent = PresentationDetent.medium

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    tile(.order, icon: "plus", tint: Color.green, filled: true).frame(maxWidth: .infinity)
                    tile(.shift, icon: "gauge.with.needle", tint: Color.primary, filled: false).frame(width: 150)
                }
                HStack(spacing: 12) {
                    tile(.expense, icon: "minus", tint: Color.red, filled: true).frame(width: 150)
                    tile(.extra, icon: "dollarsign.square", tint: Color.primary, filled: false).frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AddStep.self) { step in
                switch step {
                case .day(let kind):
                    DayStep(kind: kind) { day in path.append(.form(kind, day)) }
                case .form(let kind, let day):
                    switch kind {
                    case .order: ManualOfferForm(day: day) { dismiss() }
                    case .shift: ShiftEditor(shift: nil, day: day, embedded: true) { dismiss() }
                    case .expense, .extra: EntryForm(kind: kind == .expense ? .expense : .extra, day: day) { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: path) { _, steps in detent = steps.isEmpty ? .medium : .large }
    }

    private func tile(_ kind: AddKind, icon: String, tint: Color, filled: Bool) -> some View {
        Button { path.append(.day(kind)) } label: {
            VStack(alignment: .leading) {
                Image(systemName: icon).font(.title3.weight(.bold))
                    .foregroundStyle(filled ? Color.white : tint)
                    .frame(width: 40, height: 40)
                    .background(filled ? tint.opacity(0.85) : Color.primary.opacity(0.12), in: Circle())
                Spacer(minLength: 16)
                Text(kind.title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Step 2: the day, on a month calendar (future days off). Tapping a day goes on to the form.
private struct DayStep: View {
    let kind: AddKind
    let next: (Date) -> Void
    @State private var day = Date()

    var body: some View {
        VStack(spacing: 12) {
            DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Theme.purple)
            Button { next(day) } label: {
                Text("Continue with " + day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(Theme.purple)
            Spacer(minLength: 0)
        }
        .padding(16)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: day) { _, picked in next(picked) }
    }
}

/// The picked day at the time of day it is now (today), or midday (other days).
private func startOf(_ day: Date) -> Date {
    let calendar = Calendar.current
    if calendar.isDateInToday(day) { return Date() }
    return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
}

private func number(_ text: String) -> Double? {
    Double(text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
}

private func amountField(_ label: String, _ prompt: String, _ text: Binding<String>, decimal: Bool = true) -> some View {
    HStack {
        Text(label)
        Spacer()
        TextField(prompt, text: text).keyboardType(decimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(.trailing).frame(maxWidth: 120)
    }
}

// MARK: Order

/// An order or offer typed in from the delivery app's card (user, Oct 15: a DoorDash food bank pickup went unread with
/// no way to add it; then: "choose whether or not it's ongoing or completed already"). Ongoing starts the trip; completed
/// goes straight into history with its times; declined only keeps the offer. The verdict is the reader's per-mile
/// break-even without a mapped drive back.
struct ManualOfferForm: View {
    enum Outcome: String, CaseIterable { case ongoing = "Ongoing", completed = "Completed", declined = "Declined" }
    @EnvironmentObject private var model: AppModel
    let onDone: () -> Void
    @State private var platform = "doordash"
    @State private var payText = ""
    @State private var milesText = ""
    @State private var minutesText = ""
    /// One name per pickup (searched in the restaurant list).
    @State private var stores = [""]
    @State private var pickups = 1
    @State private var dropoffs = 1
    @State private var outcome: Outcome
    @State private var offeredAt: Date
    @State private var deliveredAt: Date

    init(day: Date, onDone: @escaping () -> Void) {
        self.onDone = onDone
        let start = startOf(day)
        let today = Calendar.current.isDateInToday(day)
        _offeredAt = State(initialValue: start)
        _deliveredAt = State(initialValue: today ? Date() : start.addingTimeInterval(30 * 60))
        _outcome = State(initialValue: today ? .ongoing : .completed)
    }

    var body: some View {
        Form {
            Section {
                Picker("Status", selection: $outcome) {
                    ForEach(Outcome.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("App", selection: $platform) {
                    ForEach(["doordash", "uber_eats", "grubhub"], id: \.self) { Text(Theme.appName($0)).tag($0) }
                }
                amountField(outcome == .completed ? "Pay (with tip)" : "Pay", "$26.70", $payText)
                amountField("Miles", "11.0", $milesText)
                amountField("Minutes on the card", "57", $minutesText, decimal: false)
                Stepper("Pickups: \(pickups)", value: $pickups, in: 1...5)
                Stepper("Drop-offs: \(dropoffs)", value: $dropoffs, in: 1...6)
            }
            Section(pickups == 1 ? "Store" : "Stores") {
                ForEach(stores.indices, id: \.self) { index in
                    StoreField(prompt: pickups == 1 ? "Store (optional)" : "Store \(index + 1) (optional)", text: $stores[index], platform: platform)
                }
            }
            Section {
                DatePicker(outcome == .declined ? "Offered at" : "Accepted at", selection: $offeredAt, in: ...Date())
                if outcome == .completed {
                    DatePicker("Delivered at", selection: $deliveredAt, in: offeredAt...max(offeredAt, Date()))
                }
            } footer: {
                Text(outcome == .ongoing ? "Starts the order, like tapping Accept." : outcome == .completed
                     ? "Goes into your history and earnings with these times." : "Kept in your offers only.")
            }
            if let offer = draft, offer.outboundMilliMiles != nil {
                Section("Verdict") {
                    VerdictChip(notice: offer.notice, large: true)
                    Text(offer.detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: pickups) { _, count in
            stores = Array((stores + Array(repeating: "", count: count)).prefix(count))
        }
        .navigationTitle("Add an order")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { if let offer = draft { save(offer) } }.disabled(draft == nil)
            }
        }
    }

    /// The offer as __APP_NAME__ would have stored it, once the pay is filled in.
    private var draft: LiveOffer? {
        guard let pay = number(payText), pay > 0 else { return nil }
        let payCents = Int((pay * 100).rounded())
        let milliMiles = number(milesText).map { Int(($0 * 1000).rounded()) }.flatMap { $0 > 0 ? $0 : nil }
        let minutes = number(minutesText).map { Int($0.rounded()) }.flatMap { $0 > 0 ? $0 : nil }
        let rules = model.rules
        var fields: [String: Any] = [:]
        if let milliMiles {
            // Same break-even as the reader: the pay covers this many miles at the rule; what's left is the allowed return.
            let maxReturn = payCents * 1000 / max(1, rules.centsPerMile) - milliMiles
            let perMile = String(format: "$%.2f/mi", Double(payCents * 1000 / milliMiles) / 100)
            let target = rules.perMileText + "/mi"
            fields["tone"] = maxReturn < 0 ? "bad" : maxReturn >= 5000 ? "good" : "tight"
            fields["maxReturnMilliMiles"] = maxReturn
            fields["notice"] = maxReturn < 0 ? perMile + " · Decline" : String(format: "Accept if return ≤ %.1f mi", Double(maxReturn) / 1000)
            var detail = maxReturn < 0 ? "Below \(target) before the drive back"
                : String(format: "Meets \(target) if the drive back is ≤ %.1f mi", Double(maxReturn) / 1000)
            if let minutes { detail += " · " + TripFormat.hourly(payCents * 60 / minutes) + " for the card's \(minutes) min, before the drive back" }
            fields["detail"] = detail
            fields["outboundMilliMiles"] = milliMiles
        } else {
            fields["tone"] = "unknown"
            fields["detail"] = "Added by hand without miles."
        }
        let names = stores.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let stamp = Int(offeredAt.timeIntervalSince1970)
        fields["seenAt"] = ISO8601DateFormatter().string(from: offeredAt)
        fields["platform"] = platform
        fields["payCents"] = payCents
        if let minutes { fields["appMinutes"] = minutes }
        if let first = names.first { fields["merchant"] = first; fields["merchants"] = names }
        fields["orderCount"] = dropoffs
        fields["pickupCount"] = pickups
        fields["dropoffCount"] = dropoffs
        fields["confidence"] = 1.0
        fields["returnNote"] = "Added by hand: no drive back was mapped."
        fields["offerId"] = "manual-\(platform)-\(stamp)"
        fields["headline"] = Theme.appName(platform) + String(format: " $%.2f", pay) + (milliMiles.map { String(format: " · %.1f mi", Double($0) / 1000) } ?? "")
        fields["fingerprint"] = "manual|\(platform)|\(payCents)|\(milliMiles ?? 0)|\(stamp)"
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LiveOffer.self, from: data)
    }

    private func save(_ offer: LiveOffer) {
        _ = model.importOffers([offer])
        switch outcome {
        case .ongoing: TripStore.shared.accept(TripOfferInfo(offer), at: offeredAt, source: "manual_entry")
        case .completed: TripStore.shared.recordCompleted(TripOfferInfo(offer), acceptedAt: offeredAt, deliveredAt: deliveredAt)
        case .declined: break
        }
        onDone()
    }
}

// MARK: Expenses, and tips, bonuses, and other earnings

struct EntryForm: View {
    let kind: MoneyEntry.Kind
    let onDone: () -> Void
    @State private var amountText = ""
    @State private var category: String
    @State private var platform = ""
    @State private var at: Date
    @State private var note = ""

    init(kind: MoneyEntry.Kind, day: Date, onDone: @escaping () -> Void) {
        self.kind = kind
        self.onDone = onDone
        _category = State(initialValue: kind == .expense ? "Gas" : "Tip")
        _at = State(initialValue: startOf(day))
    }

    var body: some View {
        Form {
            Section {
                amountField("Amount", "$0.00", $amountText)
                Picker("Type", selection: $category) {
                    ForEach(kind == .expense ? MoneyEntry.expenseCategories : MoneyEntry.extraCategories, id: \.self) { Text($0).tag($0) }
                }
                if kind == .extra {
                    Picker("App", selection: $platform) {
                        Text("None").tag("")
                        ForEach(["doordash", "uber_eats", "grubhub"], id: \.self) { Text(Theme.appName($0)).tag($0) }
                    }
                }
                DatePicker("When", selection: $at, in: ...Date())
                TextField("Note (optional)", text: $note)
            } footer: {
                Text(kind == .expense ? "Subtracted from your earnings as net on the Earnings page."
                     : "Added to your earnings for that day (and that app's share). For a tip on one order, edit the order's pay instead.")
            }
        }
        .navigationTitle(kind == .expense ? "Add an expense" : "Add earnings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let cents = cents else { return }
                    let trimmed = note.trimmingCharacters(in: .whitespaces)
                    EntryStore.shared.add(MoneyEntry(id: "\(kind.rawValue)-\(Int(Date().timeIntervalSince1970 * 1000))", kind: kind, at: at,
                                                     amountCents: cents, category: category, platform: platform.isEmpty ? nil : platform,
                                                     note: trimmed.isEmpty ? nil : trimmed))
                    onDone()
                }
                .disabled(cents == nil)
            }
        }
    }

    private var cents: Int? {
        guard let value = number(amountText), value > 0 else { return nil }
        return Int((value * 100).rounded())
    }
}
