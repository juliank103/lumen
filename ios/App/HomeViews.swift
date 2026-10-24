import SwiftUI

// Home redesign (user, Oct 21: approved the preview, artifact "__APP_NAME__ Home Redesign"). Three states, one at a time:
// an offer in (the verdict first), waiting (today's money and goals), on an order (the next stop and one big button).
// Dark-first; purple only on what you can tap; verdict colors only on verdicts, always with an icon.

/// An offer, verdict first: ACCEPT/CHECK/DECLINE, then $/mi and $/hr large, pay and miles, and a bar that runs out as the
/// offer's decision time passes.
struct HomeOfferCard: View {
    let offer: LiveOffer
    let onDismiss: () -> Void
    @State private var dragX: CGFloat = 0

    private var verdict: Verdict { Verdict(notice: offer.notice) }

    /// An icon for the why line, from its first words.
    static func whyIcon(_ why: String) -> String {
        why.hasPrefix("On your way home") ? "house" : why.hasPrefix("Too slow") || why.hasPrefix("Time") ? "clock"
            : why.hasPrefix("Long drive back") ? "arrow.uturn.backward" : why.contains("map pin") ? "mappin"
            : why.hasPrefix("Drop-off not found") ? "mappin.slash" : why.hasPrefix("Numbers") ? "exclamationmark.triangle"
            : why.contains("town center") || why.contains("drop-off street") ? "road.lanes" : "info.circle"
    }

    /// "$1.42/mi · $31/hr · Accept" → ("$1.42", "$31").
    private var rates: (perMile: String?, perHour: String?) {
        let parts = (offer.notice ?? "").components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        let mile = parts.first { $0.hasSuffix("/mi") }.map { String($0.dropLast(3)) }
        let hour = parts.first { $0.hasSuffix("/hr") }.map { String($0.dropLast(3)) }
        return (mile, hour)
    }

    var body: some View {
        let color = Theme.color(verdict)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                AppLogo(platform: offer.platform, size: 34)
                Text(offer.merchants?.joined(separator: " + ") ?? offer.merchant ?? Theme.appName(offer.platform))
                    .font(.headline).lineLimit(1)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.body.weight(.bold)).foregroundStyle(Theme.secondaryText)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Dismiss offer")
            }
            HStack(spacing: 12) {
                Image(systemName: verdict.icon).font(.system(size: 26, weight: .black))
                Text(verdict.banner).font(.system(size: 28, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
            }
            .foregroundStyle(Theme.ground)
            .padding(.horizontal, 18).frame(height: 62)
            .background(color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(alignment: .top) {
                bigNumber(rates.perMile ?? "—", "per mile")
                bigNumber(rates.perHour ?? "—", "per hour")
            }
            HStack {
                Text(TripFormat.dollars(offer.payCents))
                Spacer()
                if let miles = offer.outboundMilliMiles {
                    let total = miles + (offer.returnMilliMiles ?? 0)
                    Text(String(format: "%.1f mi", Double(total) / 1000) + (offer.returnMilliMiles != nil ? " incl. return" : ""))
                }
            }
            .font(.body.weight(.medium)).foregroundStyle(Theme.secondaryText)
            // The one reason behind the verdict (user, Oct 22).
            if let why = offer.why {
                Label(why, systemImage: Self.whyIcon(why)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, 1 - context.date.timeIntervalSince(offer.seenAt) / AppModel.offerHeroSeconds)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(color).frame(width: geo.size.width * left)
                    }
                }
                .frame(height: 6)
            }
            AcceptButton(offer: offer)
        }
        .padding(22)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(color, lineWidth: 2))
        .offset(x: dragX)
        .opacity(1 - min(0.6, Double(abs(dragX)) / 300))
        .simultaneousGesture(DragGesture(minimumDistance: 20)
            .onChanged { value in if abs(value.translation.width) > abs(value.translation.height) { dragX = value.translation.width } }
            .onEnded { value in
                if abs(value.translation.width) > 110, abs(value.translation.width) > abs(value.translation.height) { onDismiss() }
                withAnimation(.spring) { dragX = 0 }
            })
    }

    private func bigNumber(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 50, weight: .heavy, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line of the running shift under an offer: earnings, pace, time, and the day's goal bar.
struct HomeShiftStrip: View {
    @ObservedObject private var shifts = ShiftStore.shared
    @ObservedObject private var goals = GoalStore.shared

    var body: some View {
        if let shift = shifts.current, let m = shifts.metrics {
            VStack(alignment: .leading, spacing: 4) {
                Text("This Shift").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                HStack(alignment: .firstTextBaseline) {
                    Text(ShiftFormat.money(m.earningsCents)).font(.title2.weight(.bold)).monospacedDigit()
                    Spacer()
                    HStack(spacing: 6) {
                        Text(ShiftFormat.rate(m.shiftHourlyCents, "hr"))
                        Text("·")
                        ShiftClock(shift: shift)
                        Text("· " + ShiftFormat.miles(m.miles.total))
                    }
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// Waiting for an offer: the shift's money large, pace/time/miles, goals, and End shift.
struct HomeWaiting: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var shifts = ShiftStore.shared
    @State private var confirmEnd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let shift = shifts.current, let m = shifts.metrics {
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.period.map { "\($0.label) shift" } ?? "This shift").font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondaryText)
                    Text(ShiftFormat.money(m.earningsCents)).font(.system(size: 72, weight: .heavy, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    HStack(spacing: 18) {
                        Text(ShiftFormat.rate(m.shiftHourlyCents, "hr"))
                        ShiftClock(shift: shift)
                        Text(ShiftFormat.miles(m.miles.total))
                    }
                    .font(.title3.weight(.semibold)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                }
            }
            GoalsCard()
            HStack(spacing: 10) {
                Circle().fill(model.isReading ? Theme.neonGreen : Color.gray).frame(width: 10, height: 10)
                    .background(Circle().fill((model.isReading ? Theme.neonGreen : Color.gray).opacity(0.18)).frame(width: 22, height: 22))
                Text(model.isReading ? "Waiting for offers" : "Not reading offers").font(.headline).foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            if shifts.current != nil {
                Button(role: .destructive) { confirmEnd = true } label: {
                    Text("End shift").font(.headline).frame(maxWidth: .infinity).frame(height: 56)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.track, lineWidth: 1.5))
                }
                .foregroundStyle(Theme.neonRed)
                .confirmationDialog("End this shift?", isPresented: $confirmEnd) {
                    Button("End shift", role: .destructive) { shifts.endByDriver() }
                } message: {
                    Text("Also stops reading offers.")
                }
            }
        }
    }
}

/// On an order: the order card (app, pay, predicted $/hr, arrival checkpoints), the next stop in big type, one big
/// button for it, and a short-lived Undo for the last step.
struct HomeOnOrder: View {
    @ObservedObject private var store = TripStore.shared
    let trip: Trip

    private var predictedHourly: Int? {
        let hours = trip.orders.compactMap { o -> Double? in
            guard let hourly = o.predictedHourlyCents, hourly > 0 else { return nil }
            return Double(o.payCents) / Double(hourly)
        }
        guard hours.count == trip.orders.count, let longest = hours.max(), longest > 0 else { return nil }
        return Int((Double(trip.orders.reduce(0) { $0 + $1.payCents }) / longest).rounded())
    }

    /// The next stop's name and the short verb for its button.
    private func describe(_ action: TripAction) -> (place: String, verb: String) {
        let order = trip.orders.first { $0.offerId == action.offerId }
        let store = order.flatMap { $0.stores.indices.contains(action.stop) ? $0.stores[action.stop] : nil } ?? "Store"
        let dropoff = (order?.dropoffs ?? 1) > 1 ? "Drop-off \(action.stop + 1)" : "Drop-off"
        switch action.kind {
        case .arrivedStore: return (store, "Arrived")
        case .leftStore: return (store, "Picked up")
        case .arrivedDropoff: return (dropoff, "Arrived")
        case .delivered: return (dropoff, "Delivered")
        default: return (action.label, "Done")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The shift (earnings, $/hr, shift clock, miles), then the order card with its own clock and pace.
            HomeShiftStrip()
            HomeTripCard(trip: trip, predictedHourly: predictedHourly)
            Spacer(minLength: 12)
            if let next = trip.actions.first {
                let what = describe(next)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next stop").font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondaryText)
                    Text(what.place).font(.system(size: 34, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.7)
                }
                Button { store.perform(next) } label: {
                    Label(what.verb, systemImage: next.kind == .delivered ? "checkmark" : "mappin.and.ellipse")
                        .font(.title2.weight(.heavy)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 76)
                        .background(Theme.purple, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(next.label)
                let others = Array(trip.actions.dropFirst())
                if !others.isEmpty {
                    Menu {
                        ForEach(others) { action in Button(action.label) { store.perform(action) } }
                    } label: {
                        Text("Other steps").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 44)
                    }
                }
            }
        }
    }
}

/// One order: app, pay, predicted $/hr, and the arrival checkpoints labelled with the stores. Tap to see or edit it;
/// ⋯ for unassign/cancel/remove.
struct HomeOrderCard: View {
    @ObservedObject private var store = TripStore.shared
    let trip: Trip
    let order: Trip.Order
    let predictedHourly: Int?
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                AppLogo(platform: order.platform, size: 34)
                Text(TripFormat.dollars(order.payCents)).font(.system(size: 28, weight: .heavy, design: .rounded))
                Spacer()
                if let predicted = predictedHourly ?? order.predictedHourlyCents {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(TripFormat.hourly(predicted)).font(.title3.weight(.bold))
                        Text("predicted").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
                if order.ended == nil { OrderOptionsMenu(trip: trip, order: order) }
            }
            OrderCheckpoints(trip: trip, order: order)
        }
        .padding(20)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { editing = true }
        .sheet(isPresented: $editing) { OrderEditor(offerId: order.offerId) }
        .accessibilityHint("Shows the order's details to view or change")
    }


}

/// The order's ⋯ menu: unassigned, cancelled, remove, and count fixes.
struct OrderOptionsMenu: View {
    let trip: Trip
    /// One order, or several from the same app (stacked): then a submenu per order, named by its stores.
    let orders: [Trip.Order]

    init(trip: Trip, order: Trip.Order) { self.trip = trip; self.orders = [order] }
    init(trip: Trip, orders: [Trip.Order]) { self.trip = trip; self.orders = orders }

    var body: some View {
        Menu {
            if orders.count == 1, let order = orders.first {
                OrderOptionsContent(trip: trip, order: order)
            } else {
                ForEach(orders) { order in
                    Menu(order.stores.joined(separator: " + ")) { OrderOptionsContent(trip: trip, order: order) }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundStyle(Theme.secondaryText)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Order options")
    }
}

/// The options for one order: unassigned, cancelled, remove, and count fixes.
struct OrderOptionsContent: View {
    @ObservedObject private var store = TripStore.shared
    let trip: Trip
    let order: Trip.Order

    var body: some View {
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
            // Fixing a wrong step any time during the order (user, Oct 22: "there's no undo button for active orders").
            if !reachedStops.isEmpty {
                Divider()
                ForEach(reachedStops, id: \.label) { stop in
                    Button("Not at \(stop.label) yet") { store.clearStop(order.offerId, store: stop.store, stop: stop.index) }
                }
            }
    }

    /// Stops of this order already marked: each store, and the last drop-off reached (an earlier one can't be cleared
    /// without the later ones).
    private var reachedStops: [(label: String, store: Bool, index: Int)] {
        var list = order.stores.enumerated()
            .filter { trip.has(.arrivedStore, order.offerId, $0.offset) || trip.has(.leftStore, order.offerId, $0.offset) }
            .map { (label: $0.element, store: true, index: $0.offset) }
        let reached = max(trip.count(.arrivedDropoff, order.offerId), trip.count(.delivered, order.offerId))
        if reached > 0 { list.append((label: order.dropoffs > 1 ? "drop-off \(reached)" : "the drop-off", store: false, index: reached - 1)) }
        return list
    }
}

/// The undo symbol on the active order card (user, Oct 23: "just an undo symbol on the actual active order card";
/// before that a bar under the step button, and before that a 10-second toast). There whenever this trip has a change to
/// take back; each tap undoes one more. VoiceOver reads what it undoes.
struct UndoButton: View {
    @ObservedObject private var store = TripStore.shared
    let trip: Trip

    private var label: String? {
        guard PreviewData.isActive else { return store.undoLabel }
        return trip.steps.max { $0.at < $1.at }?.label ?? trip.orders.last.map { "Accepted · " + ($0.stores.first ?? "") }
    }

    var body: some View {
        if let label {
            Button { store.undo() } label: {
                Image(systemName: "arrow.uturn.backward").font(.body.weight(.bold)).foregroundStyle(Theme.purple)
                    .frame(width: 36, height: 44)
            }
            .sensoryFeedback(.impact, trigger: store.undoLabel)
            .accessibilityLabel("Undo " + label)
        }
    }
}

extension Verdict {
    var banner: String {
        switch self {
        case .accept: return "ACCEPT"
        case .decline: return "DECLINE"
        case .maybe: return "CHECK RETURN"
        }
    }
    var icon: String {
        switch self {
        case .accept: return "checkmark"
        case .decline: return "xmark"
        case .maybe: return "minus"
        }
    }
}

/// The trip on one card (user, Oct 21: "a stacked offer shouldn't have multiple progress bars"): a row per order (app,
/// pay, stores when stacked, ⋯; tap to see or edit it), the predicted $/hr, and one progress bar for all the stops.
struct HomeTripCard: View {
    let trip: Trip
    let predictedHourly: Int?
    @State private var editing: OrderEditTarget?

    /// One row per app (user, Oct 21: within one app you only ever know the stacked total — "$19.35, not the two
    /// separate amounts"): its total pay and all its stores. Two apps at once get a row each.
    private var groups: [[Trip.Order]] {
        var order: [String] = [], byApp: [String: [Trip.Order]] = [:]
        for o in trip.orders {
            if byApp[o.platform] == nil { order.append(o.platform) }
            byApp[o.platform, default: []].append(o)
        }
        return order.compactMap { byApp[$0] }
    }

    var body: some View {
        let groups = self.groups
        let multiApp = groups.count > 1
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, orders in
                HStack(spacing: 10) {
                    AppLogo(platform: orders[0].platform, size: multiApp ? 26 : 34)
                    Text(TripFormat.dollars(orders.reduce(0) { $0 + $1.payCents }))
                        .font(.system(size: multiApp ? 22 : 28, weight: .heavy, design: .rounded))
                        .lineLimit(1).fixedSize()   // Never wraps; the store names shorten instead (screens, Oct 23: "$19.3 / 5").
                    if orders.count > 1 || multiApp {
                        Text(orders.flatMap(\.stores).joined(separator: " + ")).font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    if !multiApp, let predicted = predictedHourly {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(TripFormat.hourly(predicted)).font(.title3.weight(.bold))
                            Text("predicted").font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    // Undo as a symbol on the card itself (user, Oct 23), next to ⋯ on the first row.
                    if index == 0 { UndoButton(trip: trip) }
                    let open = orders.filter { $0.ended == nil }
                    if !open.isEmpty { OrderOptionsMenu(trip: trip, orders: open) }
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = OrderEditTarget(offerId: (orders.last { $0.ended == nil } ?? orders[0]).offerId) }
            }
            if multiApp, let predicted = predictedHourly {
                Text("Together " + TripFormat.hourly(predicted) + " predicted").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            }
            OrderCheckpoints(trip: trip)
            // Time on this order and its pace, under the progress bar in the same card (user, Oct 21).
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TripFormat.clock(trip.elapsed(context.date)))
                            .font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                        Text("on this order").font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        // The live pace means little in the first minutes ($580/hr at 1:34): the offer's predicted $/hr
                        // until 10 minutes in, then the live pace.
                        let early = trip.elapsed(context.date) < 600 && predictedHourly != nil
                        let pace = early ? predictedHourly : trip.paceCents(context.date)
                        Text(pace.map(TripFormat.hourly) ?? "—")
                            .font(.system(size: 28, weight: .heavy, design: .rounded)).monospacedDigit()
                            .foregroundStyle((pace ?? 0) >= RulesStore.current.hourlyTargetCents ? Theme.neonGreen : Theme.neonYellow)
                        Text(early ? "predicted" : "pace").font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .padding(20)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .sheet(item: $editing) { target in OrderEditor(offerId: target.offerId) }
    }
}

/// An offer that comes in while you're on an order (user, Oct 21: "shouldn't take up the whole screen"): one row —
/// the verdict, $/mi and $/hr, pay and store, add it to the trip, or dismiss.
struct HomeOfferRow: View {
    let offer: LiveOffer
    let onDismiss: () -> Void

    var body: some View {
        let verdict = Verdict(notice: offer.notice)
        let color = Theme.color(verdict)
        let parts = (offer.notice ?? "").components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        let rates = parts.filter { $0.hasSuffix("/mi") || $0.hasSuffix("/hr") }.joined(separator: " · ")
        HStack(spacing: 12) {
            Image(systemName: verdict.icon).font(.system(size: 16, weight: .black)).foregroundStyle(Theme.ground)
                .frame(width: 34, height: 34).background(color, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(rates.isEmpty ? verdict.banner : rates).font(.headline).monospacedDigit().lineLimit(1)
                Text([TripFormat.dollars(offer.payCents), offer.merchants?.first ?? offer.merchant].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 4)
            AcceptButton(offer: offer, compact: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondaryText).frame(width: 36, height: 44)
            }
            .accessibilityLabel("Dismiss offer")
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(color, lineWidth: 1.5))
    }
}

extension Trip {
    /// The offers' predicted $/hr for the whole trip (stacked: all pay over the longest order's predicted time).
    var predictedHourlyCents: Int? {
        let hours = orders.compactMap { o -> Double? in
            // The app's ETA you entered (plus the predicted drive back) beats __APP_NAME__'s own estimate (Oct 23).
            if let eta = o.appEtaMinutes { return Double(eta + (o.predictedReturnMinutes ?? 0)) / 60 }
            guard let hourly = o.predictedHourlyCents, hourly > 0 else { return nil }
            return Double(o.payCents) / Double(hourly)
        }
        guard hours.count == orders.count, let longest = hours.max(), longest > 0 else { return nil }
        return Int((Double(orders.reduce(0) { $0 + $1.payCents }) / longest).rounded())
    }
}
