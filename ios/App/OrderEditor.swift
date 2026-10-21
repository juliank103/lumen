import SwiftUI

struct OrderEditTarget: Identifiable { let offerId: String; var id: String { offerId } }

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
                                                   storeEdits: stores.map { ($0.from, $0.name) }, dropoffs: dropoffs)
                        dismiss()
                    }
                    .disabled(cents == nil || stores.isEmpty)
                }
            }
            .sensoryFeedback(.selection, trigger: stores.map(\.id))
            .onAppear(perform: load)
        }
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
        delivered = trip.count(.delivered, offerId)
        minimumDropoffs = max(1, trip.count(.arrivedDropoff, offerId), delivered)
    }
}
