import SwiftUI

/// Offers by day, newest first, filtered to what you took (user, Oct 14: completed orders were lost in the list).
struct OffersTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var trips = TripStore.shared
    @State private var filter = Filter.taken
    @State private var deleting: LiveOffer?

    enum Filter: String, CaseIterable, Identifiable {
        case taken = "Taken", completed = "Completed", endedEarly = "Ended early", all = "All"
        var id: String { rawValue }
    }

    private func outcome(_ offer: LiveOffer) -> Trip.Order? {
        trips.trip(for: offer.offerId ?? offer.id)?.orders.first { $0.offerId == (offer.offerId ?? offer.id) }
    }

    private var shown: [LiveOffer] {
        model.offers.reversed().filter { offer in
            let order = outcome(offer)
            switch filter {
            case .all: return true
            case .taken: return order != nil
            case .completed: return order?.completed == true
            case .endedEarly: return order.map { $0.ended != nil && !$0.completed } ?? false
            }
        }
    }

    private var days: [(day: Date, offers: [LiveOffer])] {
        let calendar = Calendar.current
        var result: [(day: Date, offers: [LiveOffer])] = []
        for offer in shown {
            let day = calendar.startOfDay(for: offer.seenAt)
            if result.last?.day == day { result[result.count - 1].offers.append(offer) } else { result.append((day, [offer])) }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 8)
                if shown.isEmpty {
                    ContentUnavailableView(filter == .all ? "No offers yet" : "Nothing here yet", systemImage: "tray",
                                           description: Text(filter == .all ? "Offers you're shown while reading will appear here."
                                                             : "Offers you tick as accepted show up here with their time and pace."))
                } else {
                    List {
                        ForEach(days, id: \.day) { group in
                            Section(dayTitle(group.day)) {
                                ForEach(group.offers) { offer in
                                    NavigationLink { OfferDetail(offer: offer) } label: { OfferRow(offer: offer, order: outcome(offer)) }
                                        .swipeActions {
                                            Button(role: .destructive) { deleting = offer } label: { Label("Delete", systemImage: "trash") }
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Offers")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AddButton() } }
            .menuButton()
            .confirmationDialog("Delete this offer?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                presenting: deleting) { offer in
                Button("Delete from history", role: .destructive) { model.deleteOffer(offer.offerId ?? offer.id) }
            } message: { offer in
                Text(outcome(offer) == nil ? "It's removed from Offers and your stats."
                     : "The offer and its order (times, pay, store waits) are removed from your history and stats.")
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInYesterday(day) ? "Yesterday"
            : day.formatted(date: .abbreviated, time: .omitted)
    }
}

/// One offer: pay and miles first, then the strongest secondary line — what happened if you took it, else
/// Lumen's verdict — then the restaurant and time in gray.
struct OfferRow: View {
    let offer: LiveOffer
    var order: Trip.Order? = nil
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AppLogo(platform: offer.platform, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(payAndMiles).font(.headline)
                if let order {
                    OrderOutcome(order: order).font(.subheadline.weight(.semibold))
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.color(Verdict(notice: offer.notice))).frame(width: 9, height: 9)
                        Text(offer.notice ?? "Reading…").font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                }
                Text([offer.merchant, offer.seenAt.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var payAndMiles: String {
        let pay = (Double(offer.payCents) / 100).formatted(.currency(code: "USD"))
        guard let miles = offer.outboundMilliMiles else { return pay }
        return pay + " · " + String(format: "%.1f mi", Double(miles) / 1000)
    }
}

/// One offer: the verdict and what happened first; the card's fields next; how Lumen decided is one tap deeper.
struct OfferDetail: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let offer: LiveOffer
    @State private var confirmDelete = false
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        AppLogo(platform: offer.platform, size: 32)
                        Text(offer.seenAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }
                    Text((Double(offer.payCents) / 100).formatted(.currency(code: "USD"))).font(.largeTitle.weight(.bold))
                    Text(summaryLine).font(.subheadline).foregroundStyle(.secondary)
                    VerdictChip(notice: offer.notice, large: true)
                    if TripStore.shared.trip(for: offer.offerId ?? offer.id) != nil {
                        Text("Lumen's estimate when the offer came in. What it actually earned is under Your trip.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    AcceptButton(offer: offer)
                }.padding(.vertical, 4)
            }
            TripResultSection(offerId: offer.offerId ?? offer.id)
            Section {
                NavigationLink("How Lumen decided") { OfferReasoning(offer: offer) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }.accessibilityLabel("Delete offer")
            }
        }
        .confirmationDialog("Delete this offer?", isPresented: $confirmDelete) {
            Button("Delete from history", role: .destructive) {
                model.deleteOffer(offer.offerId ?? offer.id)
                dismiss()
            }
        } message: {
            Text("The offer, and its order if you took it, are removed from your history and stats.")
        }
        .navigationTitle(Theme.appName(offer.platform))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "Olive Garden · 11.9 mi · 56 min · to Springfield"
    private var summaryLine: String {
        [offer.merchant, offer.outboundMilliMiles.map { String(format: "%.1f mi", Double($0) / 1000) },
         offer.appMinutes.map { "\($0) min" }, offer.dropoffArea.map { "to " + $0 }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The technical side of one offer: the reasoning, the return route, timings, and the reader's trace.
struct OfferReasoning: View {
    let offer: LiveOffer
    var body: some View {
        List {
            Section("Verdict") {
                Text(offer.detail)
                if let first = offer.preliminaryNotice, first != offer.notice {
                    Text("First notification: \(first)" + (offer.updated == true ? " → update sent" : "")).foregroundStyle(.secondary)
                }
                if offer.confidence < 0.9 { Text("Check this reading against the app").foregroundStyle(.orange) }
            }
            Section("Return and time") {
                row("Return trip", offer.returnMilliMiles.map { String(format: "%.1f mi", Double($0) / 1000) })
                row("Return worked out from", offer.returnKind.map(Self.kindName))
                if let note = offer.tripTimeNote { Text(note).font(.subheadline) }
                if let note = offer.returnNote { Text("Return not calculated: \(note)").font(.subheadline) }
            }
            Section("Timing") {
                row("First notification", offer.latencyFirstMs.map { String(format: "%.1f s after the card appeared", Double($0) / 1000) })
                row("Final verdict", offer.latencyRefinedMs.map { String(format: "%.1f s", Double($0) / 1000) })
                row("Reading confidence", "\(Int((offer.confidence * 100).rounded()))%")
            }
            if let debug = offer.returnDebug {
                Section("Trace") { Text(debug).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("How Lumen decided")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func kindName(_ kind: String) -> String {
        ["dropoff": "the drop-off street", "dropoff_town": "the drop-off town", "map": "the offer map",
         "worst_case": "the longest possible return"][kind] ?? kind
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
        }
    }
}

/// "✓ Completed · 24 min · $26/hr", "Unassigned after 18 min", or "In progress" for an offer you took.
struct OrderOutcome: View {
    let order: Trip.Order
    var body: some View {
        Text(text).foregroundStyle(order.completed ? Color.green : order.ended == nil ? Color.primary : Color.orange)
    }
    private var text: String {
        guard order.ended != nil, let minutes = order.minutes else { return "In progress" }
        let time = TripFormat.minutes(minutes)
        if order.completed {
            // Pace including the predicted drive back, like the verdict; without a prediction it's the order alone.
            if let pace = order.paceWithReturnCents, order.predictedReturnMinutes != nil { return "✓ Completed · " + time + " · " + TripFormat.hourly(pace) + " incl. return" }
            return "✓ Completed · " + time + (order.paceCents.map { " · " + TripFormat.hourly($0) + " order pace" } ?? "")
        }
        return (order.ended ?? "Ended").capitalized + " after " + time
    }
}
