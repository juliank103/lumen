import SwiftUI

/// The active trip on the Dash tab: running timer and live pace, each order's progress, and one big button for the
/// most likely next step (the rest under "Other next steps"). Undo fixes a mistaken tap.
struct TripCard: View {
    @ObservedObject private var store = TripStore.shared
    let trip: Trip
    @ScaledMetric(relativeTo: .largeTitle) private var clockSize: CGFloat = 42

    /// Predicted $/hr for the trip from each offer's verdict (incl. the drive back). Stacked orders share their time, so
    /// the trip takes about as long as its longest order: all their pay over that time. Nil without a prediction.
    private var predictedHourly: Int? {
        let hours = trip.orders.compactMap { o -> Double? in
            guard let hourly = o.predictedHourlyCents, hourly > 0 else { return nil }
            return Double(o.payCents) / Double(hourly)
        }
        guard hours.count == trip.orders.count, let longest = hours.max(), longest > 0 else { return nil }
        return Int((Double(trip.orders.reduce(0) { $0 + $1.payCents }) / longest).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(trip.orders.count > 1 ? "Current orders" : "Current order").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { store.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .font(.caption.weight(.bold)).disabled(!store.canUndo)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .firstTextBaseline) {
                    Text(TripFormat.clock(trip.elapsed(context.date)))
                        .font(.system(size: clockSize, weight: .heavy, design: .rounded)).monospacedDigit()
                    Spacer()
                    // The offer's predicted $/hr (user, Oct 18: the running "so far" pace read $253/hr six minutes in).
                    if let predicted = predictedHourly {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(TripFormat.hourly(predicted)).font(.title3.weight(.heavy))
                                .foregroundStyle(predicted >= RulesStore.current.hourlyTargetCents ? Color.green : Color.orange)
                            Text("predicted $/hr").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(trip.orders) { order in OrderProgress(trip: trip, order: order) }
            if !trip.actions.isEmpty {
                // The next step is the big button at the bottom of the Dash (thumb zone); other possible steps here.
                let others = Array(trip.actions.dropFirst())
                if !others.isEmpty {
                    Menu {
                        ForEach(others) { action in Button(action.label) { store.perform(action) } }
                    } label: {
                        Label("Other next steps", systemImage: "list.bullet").font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .dasherCard()
    }
}

/// The order's stages as a line of checkpoints (user, Oct 18): accepted, then each store (arrived, picked up), then each
/// drop-off (arrived, delivered). Done ones fill in, the next one is ringed, and the line between them fills as it goes.
struct OrderCheckpoints: View {
    struct Stage { let label: String; let done: Bool; let left: Bool }
    let stages: [Stage]

    /// One order's stops: each store, then each drop-off. `done`: arrived; `left`: picked up / delivered there.
    init(trip: Trip, order: Trip.Order) {
        stages = Self.numbered(Self.stops(trip, order).map(\.stage))
    }

    /// The whole trip on one bar (user, Oct 21: "a stacked offer shouldn't have multiple progress bars"): the stops already
    /// reached in the order you reached them, then the rest — stores before drop-offs, in the order the orders came in.
    init(trip: Trip) {
        let all = trip.orders.flatMap { Self.stops(trip, $0) }
        let reached = all.filter { $0.stage.done }.sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
        // Stores before drop-offs, otherwise in the orders' own order (a stable sort).
        let ahead = all.enumerated().filter { !$0.element.stage.done }
            .sorted { ($0.element.store ? 0 : 1, $0.offset) < ($1.element.store ? 0 : 1, $1.offset) }.map(\.element)
        stages = Self.numbered((reached + ahead).map(\.stage))
    }

    /// Drop-offs numbered along the bar when there's more than one.
    private static func numbered(_ list: [Stage]) -> [Stage] {
        guard list.filter({ $0.label == "Drop-off" }).count > 1 else { return list }
        var n = 0
        return list.map { stage in
            guard stage.label == "Drop-off" else { return stage }
            n += 1
            return Stage(label: "Drop-off \(n)", done: stage.done, left: stage.left)
        }
    }

    private struct Stop { let stage: Stage; let at: Date?; let store: Bool }

    private static func stops(_ trip: Trip, _ order: Trip.Order) -> [Stop] {
        let done = order.completed
        var list: [Stop] = []
        for (stop, store) in order.stores.enumerated() {
            let left = done || trip.has(.leftStore, order.offerId, stop)
            let arrival = trip.steps.first { $0.offerId == order.offerId && $0.stop == stop && ($0.kind == .arrivedStore || $0.kind == .leftStore) }?.at
            list.append(Stop(stage: Stage(label: store, done: done || arrival != nil || left, left: left), at: arrival ?? (done ? order.endedAt : nil), store: true))
        }
        let arrivals = trip.steps.filter { $0.offerId == order.offerId && ($0.kind == .arrivedDropoff || $0.kind == .delivered) }.map(\.at).sorted()
        let delivered = trip.count(.delivered, order.offerId)
        for d in 0..<max(1, order.dropoffs) {
            let arrived = done || max(trip.count(.arrivedDropoff, order.offerId), delivered) > d
            let at = arrivals.indices.contains(d) ? arrivals[d] : (done ? order.endedAt : nil)
            list.append(Stop(stage: Stage(label: "Drop-off", done: arrived, left: done || delivered > d), at: at, store: false))
        }
        return list
    }

    /// A traditional progress bar (user, Oct 21: "the progress bar is ugly", then three sketches): empty until the first
    /// arrival, the fill runs to the last stop reached, a ring per stop that turns bold when you're there and solid when
    /// you're done there, the stop's name centered under it.
    var body: some View {
        let stages = self.stages
        let n = max(1, stages.count)
        let reached = stages.prefix { $0.done }.count
        // The fill reaches each stop's circle on arrival and waits there until the next arrival (user's sketches, Oct 21).
        let fill = Double(reached) / Double(n)
        GeometryReader { geo in
            // Even spacing with half a step left after the last circle, so every name fits under its circle without
            // running into the next (screens, Oct 21: "Drop-off 1Drop-off 2").
            let segment = geo.size.width / (Double(n) + 0.5), w = segment * Double(n)
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.track).frame(width: w, height: 8).offset(y: 7)
                // Empty until the first arrival (user's sketch, Oct 21): no purple at all before the store.
                if fill > 0 {
                    Capsule().fill(Theme.purple).frame(width: w * fill, height: 8).offset(y: 7)
                        .animation(.easeOut(duration: 0.4), value: fill)
                }
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    let x = segment * Double(index + 1)
                    marker(left: stage.left, here: stage.done && !stage.left)
                        .position(x: x, y: 11)
                    // Each stop's name centered under its circle.
                    Text(stage.label)
                        .font(.caption.weight(index == reached ? .bold : .medium))
                        .foregroundStyle(stage.done || index == reached ? Color.primary : Theme.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: segment - 4)
                        .position(x: x, y: 36)
                }
            }
        }
        .frame(height: 46)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reached) of \(stages.count) stops reached" + (reached < stages.count ? ", next: " + stages[reached].label : ""))
    }

    /// The user's sketches (Oct 21): ahead = plain gray ring; here (arrived, not yet left) = bold purple ring the fill
    /// reaches; done there (picked up / delivered) = solid purple.
    private func marker(left: Bool, here: Bool) -> some View {
        ZStack {
            Circle().fill(left ? Theme.purple : Theme.ground).frame(width: here ? 26 : 22, height: here ? 26 : 22)
            Circle().stroke(left || here ? Theme.purple : Theme.track, lineWidth: here ? 4 : 2).frame(width: here ? 26 : 22, height: here ? 26 : 22)
        }
    }
}

/// One order inside the trip: app, pay, stores and drop-offs done, and a menu for unassign/cancel/count fixes.
/// Tap it to see and change its details — pickups, stores, drop-offs, pay (user, Oct 18).
struct OrderProgress: View {
    @ObservedObject private var store = TripStore.shared
    let trip: Trip
    let order: Trip.Order
    @State private var editing = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { editing = true } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        AppLogo(platform: order.platform, size: 22)
                        Text(TripFormat.dollars(order.payCents)).font(.subheadline.weight(.bold))
                        if let ended = order.ended { Text("· " + ended).font(.caption).foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    Text(order.stores.joined(separator: " + ")).font(.subheadline.weight(.semibold)).lineLimit(1)
                    OrderCheckpoints(trip: trip, order: order).padding(.vertical, 4)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the order's details to view or change")
            .sheet(isPresented: $editing) { OrderEditor(offerId: order.offerId) }
            Spacer()
            if order.ended == nil {
                Menu {
                    Menu("I unassigned it") {
                        Button("Long wait at the store") { store.end(order.offerId, .unassigned(reason: "excessive_wait")) }
                        Button("Store closed") { store.end(order.offerId, .unassigned(reason: "restaurant_closed")) }
                        Button("Order already picked up") { store.end(order.offerId, .unassigned(reason: "order_already_picked_up")) }
                        Button("Other reason") { store.end(order.offerId, .unassigned(reason: "unknown")) }
                    }
                    Menu("It was cancelled") {
                        Button("By the customer") { store.end(order.offerId, .cancelled(by: "customer")) }
                        Button("By the store") { store.end(order.offerId, .cancelled(by: "restaurant")) }
                        Button("By the app") { store.end(order.offerId, .cancelled(by: "platform")) }
                    }
                    Button("Remove this order", role: .destructive) { store.deleteOrder(order.offerId) }
                    Divider()
                    Button("Add a drop-off") { store.adjust(order.offerId, dropoffs: 1) }
                    if order.dropoffs > max(1, trip.count(.arrivedDropoff, order.offerId)) {
                        Button("Remove a drop-off") { store.adjust(order.offerId, dropoffs: -1) }
                    }
                    Button("Add a store") { store.adjust(order.offerId, addStore: true) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.purple)
                        .accessibilityLabel("Order options")
                }
            }
        }
    }

    /// Where this order stands, in plain words (review: "Stores 1/1 · drop-offs 0/1" read like a spreadsheet).
    private var progress: String {
        let stores = order.stores.indices
        let left = stores.filter { trip.has(.leftStore, order.offerId, $0) }.count
        let delivered = trip.count(.delivered, order.offerId)
        if let ended = order.ended { return ended == "completed" ? "Delivered" : ended.capitalized }
        if let here = stores.first(where: { trip.has(.arrivedStore, order.offerId, $0) && !trip.has(.leftStore, order.offerId, $0) }) {
            return "At \(order.stores[here])"
        }
        if left < order.stores.count {
            return order.stores.count > 1 ? "Picked up \(left) of \(order.stores.count) stores" : "Heading to the store"
        }
        if trip.count(.arrivedDropoff, order.offerId) > delivered { return "At the drop-off" }
        return order.dropoffs > 1 ? "Picked up · \(delivered) of \(order.dropoffs) delivered" : "Picked up · heading to the customer"
    }
}

/// "I accepted this" on an offer (or "Add as stacked order" during a trip). Hidden once the offer is in a trip.
struct AcceptButton: View {
    @ObservedObject private var store = TripStore.shared
    let offer: LiveOffer
    var compact = false

    var body: some View {
        if store.trip(for: offer.offerId ?? offer.id) == nil {
            if compact {
                Button { store.accept(TripOfferInfo(offer)) } label: {
                    Image(systemName: store.active == nil ? "checkmark.circle.fill" : "plus.circle.fill").font(.title2)
                }
                .foregroundStyle(Theme.purple)
                .accessibilityLabel(store.active == nil ? "I accepted this" : "Add as stacked order")
            } else {
                Button { store.accept(TripOfferInfo(offer)) } label: {
                    Label(store.active == nil ? "I accepted this" : "Add as stacked order",
                          systemImage: store.active == nil ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.headline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(Theme.purple)
            }
        }
    }
}

/// Looking back at an accepted offer: what __APP_NAME__ predicted next to what happened (review: the trust loop), the real
/// pay (editable — tips change it), and each store's wait.
struct TripResultSection: View {
    @ObservedObject private var store = TripStore.shared
    let offerId: String
    /// The drive back the offer's verdict counted, to show next to the real one.
    var estimatedReturnMilliMiles: Int? = nil
    @State private var editingPay = false
    @State private var editingOrder: OrderEditTarget?
    @State private var payText = ""

    var body: some View {
        if let trip = store.trip(for: offerId), let order = trip.orders.first(where: { $0.offerId == offerId }) {
            Section {
                row("Accepted", order.acceptedAt.formatted(date: .omitted, time: .shortened))
                if let minutes = order.minutes {
                    row(order.completed ? "Took" : "Ended (\(order.ended ?? "?")) after", TripFormat.minutes(minutes))
                    // What the order actually earned (the verdict above is the estimate made when the offer came in).
                    if let pace = order.paceWithReturnCents, order.predictedReturnMinutes != nil {
                        row("Real $/hr, with drive back", TripFormat.hourly(pace))
                    } else if let pace = order.paceCents {
                        row("Real $/hr", TripFormat.hourly(pace))
                    }
                } else {
                    row("Status", "In progress")
                }
                // The real drive back from where it was delivered (reader upgrade 1, Oct 23).
                if let real = order.actualReturnMilliMiles {
                    row("Drive back", (estimatedReturnMilliMiles.map { String(format: "estimated %.1f · ", Double($0) / 1000) } ?? "")
                        + String(format: "really %.1f mi", Double(real) / 1000))
                }
                // Timed on the shift clock (user, Oct 15): shift time since the previous delivery, idle included.
                if order.completed, let c = ShiftStore.shared.completion(for: offerId, acceptedAt: order.acceptedAt) {
                    row("Shift time it took", TripFormat.minutes(Double(c.sinceLastSeconds) / 60)
                        + (c.orderHourlyCents.map { " · " + TripFormat.hourly($0) } ?? ""))
                    if let hourly = c.hourlyCents {
                        row("Shift after it", ShiftFormat.money(c.earningsCents) + " in " + ShiftFormat.duration(c.clockSeconds) + " · " + TripFormat.hourly(hourly))
                    }
                }
                if order.completed {
                    Button { editingOrder = OrderEditTarget(offerId: offerId) } label: {
                        HStack {
                            Text("Pay").foregroundStyle(.primary)
                            Spacer()
                            Text(ShiftFormat.money(order.payCents) + (order.offerPayCents != nil ? " (offer \(ShiftFormat.money(order.offerPayCents)))" : ""))
                                .foregroundStyle(.secondary)
                            Image(systemName: "pencil").font(.caption).foregroundStyle(Theme.purple)
                        }
                    }
                }
                ForEach(Array(order.stores.enumerated()), id: \.offset) { stop, name in
                    if let arrived = trip.time(.arrivedStore, offerId, stop) {
                        let left = trip.time(.leftStore, offerId, stop)
                        row("Wait at \(name)", left.map { TripFormat.minutes($0.timeIntervalSince(arrived) / 60) }
                            ?? (order.ended == nil ? "waiting…" : "≥ " + TripFormat.minutes(((order.endedAt ?? arrived).timeIntervalSince(arrived)) / 60)))
                    }
                }
                if trip.orders.count > 1, let ended = trip.endedAt {
                    let seconds = ended.timeIntervalSince(trip.startedAt)
                    row("All \(trip.orders.count) orders together", TripFormat.minutes(seconds / 60)
                        + (seconds >= 60 && trip.payCents > 0 ? " · " + TripFormat.hourly(Int(Double(trip.payCents) * 3600 / seconds)) : ""))
                }
            } header: {
                Text("What happened")
            }
            .sheet(item: $editingOrder) { target in OrderEditor(offerId: target.offerId) }
            .alert("Actual pay", isPresented: $editingPay) {
                TextField("Dollars", text: $payText).keyboardType(.decimalPad)
                Button("Save") {
                    if let dollars = Double(payText.replacingOccurrences(of: "$", with: "")) { store.adjustPay(offerId, cents: Int((dollars * 100).rounded())) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("What the app actually paid, with tips. Totals use it.")
            }
            if order.completed, order.predictedTripMinutes != nil || order.predictedHourlyCents != nil {
                Section {
                    compare("Time to deliver", order.predictedTripMinutes.map { "\($0) min" }, order.minutes.map { TripFormat.minutes($0) })
                    compare("$/hr with drive back", order.predictedHourlyCents.map { TripFormat.hourly($0) }, order.paceWithReturnCents.map { TripFormat.hourly($0) })
                } header: {
                    HStack {
                        Text("Predicted vs actual")
                        InfoNote(title: "Predicted vs actual", text: "Real time plus the predicted drive back.")
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    private func compare(_ label: String, _ predicted: String?, _ actual: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(predicted ?? "—").foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            Text(actual ?? "—").fontWeight(.semibold)
        }
        .monospacedDigit()
    }
}

enum TripFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
    static func dollars(_ cents: Int) -> String { (Double(cents) / 100).formatted(.currency(code: "USD").precision(.fractionLength(cents % 100 == 0 ? 0 : 2))) }
    static func hourly(_ cents: Int) -> String { "$\(cents / 100)/hr" }
    static func minutes(_ value: Double) -> String { value < 1 ? "<1 min" : "\(Int(value.rounded())) min" }
}
