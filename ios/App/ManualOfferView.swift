import SwiftUI

/// An offer Lumen didn't read, typed in from the delivery app's card (user, Oct 15: a DoorDash food bank pickup
/// went unread and there was no way to add it). It gets the same per-mile check as a read offer, minus the mapped
/// return (stated as "Accept if return ≤ N mi"), joins the offer history, and can start the trip when accepted.
struct ManualOfferView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var platform = "doordash"
    @State private var payText = ""
    @State private var milesText = ""
    @State private var minutesText = ""
    @State private var store = ""
    @State private var pickups = 1
    @State private var dropoffs = 1
    @State private var seenAt = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("App", selection: $platform) {
                        ForEach(["doordash", "uber_eats", "grubhub"], id: \.self) { Text(Theme.appName($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    field("Pay", "$26.70", $payText)
                    field("Miles", "11.0", $milesText)
                    field("Minutes (optional)", "57", $minutesText, decimal: false)
                    TextField("Store (optional)", text: $store).textInputAutocapitalization(.words)
                    Stepper("Pickups: \(pickups)", value: $pickups, in: 1...5)
                    Stepper("Drop-offs: \(dropoffs)", value: $dropoffs, in: 1...6)
                    DatePicker("Offered at", selection: $seenAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text("As shown on the offer card.")
                }
                if let offer = draft {
                    Section {
                        VerdictChip(notice: offer.notice, large: true)
                        Text(offer.detail).font(.subheadline).foregroundStyle(.secondary)
                    } header: {
                        Text("Verdict")
                    }
                    Section {
                        Button { save(offer, accepted: true) } label: {
                            Label("I accepted it", systemImage: "checkmark.circle.fill").font(.headline)
                        }
                        Button { save(offer, accepted: false) } label: {
                            Label("I declined it", systemImage: "xmark.circle")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add an offer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>, decimal: Bool = true) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(prompt, text: text).keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing).frame(maxWidth: 120)
        }
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    /// The offer as Lumen would have stored it, once pay and miles are filled in.
    private var draft: LiveOffer? {
        guard let pay = Self.number(payText), pay > 0, let miles = Self.number(milesText), miles > 0 else { return nil }
        let payCents = Int((pay * 100).rounded()), milliMiles = Int((miles * 1000).rounded())
        let minutes = Self.number(minutesText).map { Int($0.rounded()) }.flatMap { $0 > 0 ? $0 : nil }
        let rules = model.rules
        // Same break-even as the reader: the pay covers this many miles at the rule; what's left is the allowed return.
        let maxReturn = payCents * 1000 / max(1, rules.centsPerMile) - milliMiles
        let perMile = String(format: "$%.2f/mi", Double(payCents * 1000 / milliMiles) / 100)
        let target = rules.perMileText + "/mi"
        let tone = maxReturn < 0 ? "bad" : maxReturn >= 5000 ? "good" : "tight"
        let notice = maxReturn < 0 ? perMile + " · Decline" : String(format: "Accept if return ≤ %.1f mi", Double(maxReturn) / 1000)
        var detail = maxReturn < 0 ? "Below \(target) before the drive back" : String(format: "Meets \(target) if the drive back is ≤ %.1f mi", Double(maxReturn) / 1000)
        if let minutes {
            detail += " · " + TripFormat.hourly(payCents * 60 / minutes) + " for the card's \(minutes) min, before the drive back"
        }
        let name = store.trimmingCharacters(in: .whitespaces)
        let stamp = Int(seenAt.timeIntervalSince1970)
        let fields: [String: Any?] = [
            "seenAt": ISO8601DateFormatter().string(from: seenAt), "platform": platform, "payCents": payCents,
            "outboundMilliMiles": milliMiles, "appMinutes": minutes, "merchant": name.isEmpty ? nil : name,
            "orderCount": dropoffs, "merchants": name.isEmpty ? [] : [name], "pickupCount": pickups, "dropoffCount": dropoffs,
            "confidence": 1.0, "tone": tone, "maxReturnMilliMiles": maxReturn, "notice": notice,
            "returnNote": "Added by hand: no drive back was mapped.", "offerId": "manual-\(platform)-\(stamp)",
            "headline": Theme.appName(platform) + String(format: " $%.2f · %.1f mi", pay, miles),
            "detail": detail, "fingerprint": "manual|\(platform)|\(payCents)|\(milliMiles)|\(stamp)"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields.compactMapValues { $0 }) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LiveOffer.self, from: data)
    }

    private func save(_ offer: LiveOffer, accepted: Bool) {
        _ = model.importOffers([offer])
        if accepted {
            // Accepted just now, or back when it was offered if it's being added afterwards.
            TripStore.shared.accept(TripOfferInfo(offer), at: max(offer.seenAt, Date().addingTimeInterval(-6 * 3600)), source: "manual_entry")
        }
        dismiss()
    }
}

/// The ＋ that opens it, for the Dash and Offers toolbars.
struct AddOfferButton: View {
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Image(systemName: "plus") }
            .accessibilityLabel("Add an offer Lumen missed")
            .sheet(isPresented: $showing) { ManualOfferView() }
    }
}
