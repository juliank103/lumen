import SwiftUI

struct OrderEditTarget: Identifiable { let offerId: String; var id: String { offerId } }

/// One recorded step in the editor: its time, or removed.
struct StepEdit: Identifiable, Equatable {
    let id: String
    let kind: Trip.StepKind
    let stop: Int
    let label: String
    let original: Date
    var at: Date
    var removed = false
    /// Arrival and leaving at one stop go together when a stop is removed.
    var pair: String { (kind == .arrivedStore || kind == .leftStore ? "s" : "d") + "\(stop)" }
}

/// One pickup in the editor: where it came from in the saved order (nil = added here) and its name.
struct StoreEdit: Identifiable, Equatable {
    let id = UUID()
    let from: Int?
    var name: String
}

/// Views and fixes an order (user, Oct 15: edit a finished order's time and pay; Oct 18: "tap the order you're
/// currently on and view/edit the details — how many pickups, drop-offs, what stores"). App, pay, pickups (add, remove,
/// rename, searched in the restaurant list), drop-offs, accepted time; for a finished order also the outcome and the
/// delivered time. Totals, shift numbers, and the trip's next steps follow; edits to the current order can be undone.
struct OrderEditor: View {
    @Environment(\.dismiss) private var dismiss
    let offerId: String
    @State private var platform = "doordash"
    @State private var payText = ""
    @State private var outcome = "completed"
    @State private var acceptedAt = Date()
    @State private var endedAt = Date()
    @State private var stores: [StoreEdit] = []
    @State private var dropoffs = 1
    @State private var minimumDropoffs = 1
    @State private var delivered = 0
    @State private var finished = false
    @State private var loaded = false
    @State private var steps: [StepEdit] = []
    /// The stored outcome ("cancelled by customer"), kept when the picker isn't changed.
    @State private var originalOutcome: String?

    private static let outcomes = [("completed", "Completed"), ("unassigned", "Unassigned"), ("cancelled", "Cancelled"), ("not finished", "Didn't finish")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("App", selection: $platform) {
                        ForEach(["doordash", "uber_eats", "grubhub"], id: \.self) { Text(Theme.appName($0)).tag($0) }
                    }
                    HStack {
                        Text("Pay")
                        Spacer()
                        TextField("$0.00", text: $payText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 120)
                    }
                    if finished {
                        Picker("Outcome", selection: $outcome) {
                            ForEach(Self.outcomes, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                }
                Section {
                    ForEach($stores) { $store in
                        let index = stores.firstIndex(where: { $0.id == store.id }) ?? 0
                        HStack {
                            StoreField(prompt: stores.count == 1 ? "Store" : "Store \(index + 1)", text: $store.name, platform: platform)
                            // Put the pickups in the order they really happen (user, Oct 20).
                            if index > 0 {
                                Button { withAnimation { stores.swapAt(index, index - 1) } } label: { Image(systemName: "arrow.up.circle") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Pick this one up earlier")
                            }
                        }
                    }
                    if stores.count < 6 {
                        Button { stores.append(StoreEdit(from: nil, name: "")) } label: { Label("Add a store", systemImage: "plus") }
                    }
                    if stores.count > 1 {
                        Menu {
                            ForEach(Array(stores.enumerated()), id: \.element.id) { index, store in
                                Button(store.name.isEmpty ? "Store \(index + 1)" : store.name, role: .destructive) {
                                    stores.removeAll { $0.id == store.id }
                                }
                            }
                        } label: {
                            Label("Remove a store", systemImage: "minus").foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text(stores.count == 1 ? "Pickup" : "Pickups (\(stores.count))")
                } footer: {
                    if stores.count > 1 { Text("↑ moves a store earlier.") }
                }
                Section {
                    Stepper("Drop-offs: \(dropoffs)", value: $dropoffs, in: minimumDropoffs...8)
                } footer: {
                    if !finished && delivered > 0 {
                        Text("\(delivered) delivered so far." + (dropoffs == delivered ? " Saving completes the order." : ""))
                    }
                }
                // Each stop's times, fixable after the order too (user, Oct 23); "Remove" for a stop never reached.
                if steps.contains(where: { !$0.removed }) {
                    Section {
                        ForEach($steps) { $step in
                            if !step.removed {
                                DatePicker(step.label, selection: $step.at, in: acceptedAt...Date(), displayedComponents: [.hourAndMinute])
                            }
                        }
                        Menu {
                            ForEach(stopNames, id: \.pair) { stop in
                                Button(stop.name, role: .destructive) {
                                    for i in steps.indices where steps[i].pair == stop.pair { steps[i].removed = true }
                                }
                            }
                        } label: {
                            Label("Remove a stop I didn't reach", systemImage: "minus.circle").foregroundStyle(.red)
                        }
                    } header: {
                        Text("Stops")
                    }
                }
                Section {
                    DatePicker("Accepted", selection: $acceptedAt, in: ...Date())
                    if finished {
                        DatePicker(outcome == "completed" ? "Delivered" : "Ended", selection: $endedAt, in: acceptedAt...max(acceptedAt, Date()))
                    }
                } footer: {
                    if finished {
                        Text("Took \(Int((max(60, endedAt.timeIntervalSince(acceptedAt)) / 60).rounded())) min.")
                    }
                }
            }
            .navigationTitle(finished ? "Edit order" : "Current order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        TripStore.shared.editOrder(offerId, platform: platform, payCents: cents ?? 0,
                                                   ended: finished ? (outcome == picked(originalOutcome) ? originalOutcome : outcome) : nil,
                                                   acceptedAt: acceptedAt, endedAt: finished ? endedAt : nil,
                                                   storeEdits: stores.map { ($0.from, $0.name) }, dropoffs: dropoffs,
                                                   stepTimes: stepTimes)
                        dismiss()
                    }
                    .disabled(cents == nil || stores.isEmpty)
                }
            }
            .sensoryFeedback(.selection, trigger: stores.map(\.id))
            .onAppear(perform: load)
        }
    }

    /// Changed steps: new time, or nil when removed.
    private var stepTimes: [String: Date?] {
        var changes: [String: Date?] = [:]
        for step in steps {
            if step.removed { changes[step.id] = .some(nil) }
            else if abs(step.at.timeIntervalSince(step.original)) >= 1 { changes[step.id] = .some(step.at) }
        }
        return changes
    }

    /// One entry per stop with steps left, for "Remove a stop".
    private var stopNames: [(pair: String, name: String)] {
        var seen: [String] = []
        var list: [(pair: String, name: String)] = []
        for step in steps where !step.removed && !seen.contains(step.pair) {
            seen.append(step.pair)
            let isStore = step.kind == .arrivedStore || step.kind == .leftStore
            let store = stores.indices.contains(step.stop) && !stores[step.stop].name.isEmpty ? stores[step.stop].name : "Store \(step.stop + 1)"
            list.append((step.pair, isStore ? store : (dropoffs > 1 ? "Drop-off \(step.stop + 1)" : "Drop-off")))
        }
        return list
    }

    private var cents: Int? {
        guard let value = Double(payText.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
        return Int((value * 100).rounded())
    }

    private func picked(_ ended: String?) -> String {
        let ended = ended ?? "completed"
        return ended.hasPrefix("cancelled") ? "cancelled" : Self.outcomes.contains { $0.0 == ended } ? ended : "not finished"
    }

    private func load() {
        guard !loaded, let trip = TripStore.shared.trip(for: offerId),
              let order = trip.orders.first(where: { $0.offerId == offerId }) else { return }
        loaded = true
        platform = order.platform
        payText = String(format: "%.2f", Double(order.payCents) / 100)
        finished = order.ended != nil
        originalOutcome = order.ended
        outcome = picked(order.ended)
        acceptedAt = order.acceptedAt
        endedAt = order.endedAt ?? Date()
        // Placeholder names ("Store 2") start empty so the field shows the restaurant search.
        stores = order.stores.enumerated().map { StoreEdit(from: $0.offset, name: $0.element.hasPrefix("Store ") ? "" : $0.element) }
        dropoffs = order.dropoffs
        steps = trip.steps.filter { $0.offerId == offerId }.sorted { $0.at < $1.at }
            .map { StepEdit(id: $0.id, kind: $0.kind, stop: $0.stop, label: $0.label, original: $0.at, at: $0.at) }
        delivered = trip.count(.delivered, offerId)
        minimumDropoffs = max(1, trip.count(.arrivedDropoff, offerId), delivered)
    }
}
