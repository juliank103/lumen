import SwiftUI

struct OrderEditTarget: Identifiable { let offerId: String; var id: String { offerId } }

/// Fixes a taken order by hand (user, Oct 15: "I'm trying to edit the time it took me to complete this order and I
/// can't"): app, pay, outcome, accepted and delivered times, and store names. Totals and shift numbers follow.
struct OrderEditor: View {
    @Environment(\.dismiss) private var dismiss
    let offerId: String
    @State private var platform = "doordash"
    @State private var payText = ""
    @State private var outcome = "completed"
    @State private var acceptedAt = Date()
    @State private var endedAt = Date()
    @State private var stores: [String] = []
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
                    DatePicker("Accepted", selection: $acceptedAt, in: ...Date())
                    if finished {
                        DatePicker(outcome == "completed" ? "Delivered" : "Ended", selection: $endedAt, in: acceptedAt...max(acceptedAt, Date()))
                    }
                } footer: {
                    if finished {
                        Text("Took \(Int((max(60, endedAt.timeIntervalSince(acceptedAt)) / 60).rounded())) min.")
                    }
                }
                if !stores.isEmpty {
                    Section {
                        ForEach(stores.indices, id: \.self) { index in
                            StoreField(prompt: "Store", text: $stores[index], platform: platform)
                        }
                        if finished, stores.count > 1 {
                            Button("Remove the last store", role: .destructive) { stores.removeLast() }
                        }
                    } header: {
                        Text(stores.count == 1 ? "Store" : "Stores")
                    } footer: {
                        if finished, stores.count > 1 { Text("For several orders picked up at one store, keep just that store.") }
                    }
                }
            }
            .navigationTitle("Edit order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        TripStore.shared.editOrder(offerId, platform: platform, payCents: cents ?? 0, ended: finished ? (outcome == picked(originalOutcome) ? originalOutcome : outcome) : nil,
                                                   acceptedAt: acceptedAt, endedAt: finished ? endedAt : nil, stores: stores)
                        dismiss()
                    }
                    .disabled(cents == nil)
                }
            }
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
        guard !loaded, let order = TripStore.shared.trip(for: offerId)?.orders.first(where: { $0.offerId == offerId }) else { return }
        loaded = true
        platform = order.platform
        payText = String(format: "%.2f", Double(order.payCents) / 100)
        finished = order.ended != nil
        originalOutcome = order.ended
        outcome = picked(order.ended)
        acceptedAt = order.acceptedAt
        endedAt = order.endedAt ?? Date()
        stores = order.stores
    }
}
