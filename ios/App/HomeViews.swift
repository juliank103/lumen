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
            VStack(alignment: .leading, spacing: 10) {
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
                    Button("End shift", role: .destructive) { shifts.end() }
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
            ForEach(trip.orders) { order in HomeOrderCard(trip: trip, order: order, predictedHourly: trip.orders.count == 1 ? predictedHourly : nil) }
            if trip.orders.count > 1, let predicted = predictedHourly {
                Text("Together " + TripFormat.hourly(predicted) + " predicted").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            }
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
            UndoToast(trip: trip)
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
            HStack {
                ForEach(Array(stopNames.enumerated()), id: \.offset) { index, name in
                    Text(name).font(.caption.weight(index == nextIndex ? .bold : .medium))
                        .foregroundStyle(index == nextIndex ? Color.primary : Theme.secondaryText)
                        .lineLimit(1)
                    if index < stopNames.count - 1 { Spacer(minLength: 4) }
                }
            }
        }
        .padding(20)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { editing = true }
        .sheet(isPresented: $editing) { OrderEditor(offerId: order.offerId) }
        .accessibilityHint("Shows the order's details to view or change")
    }

    private var stopNames: [String] {
        order.stores + (0..<max(1, order.dropoffs)).map { order.dropoffs > 1 ? "Drop-off \($0 + 1)" : "Drop-off" }
    }

    private var nextIndex: Int? {
        let arrivedStores = order.stores.indices.map { trip.has(.arrivedStore, order.offerId, $0) || trip.has(.leftStore, order.offerId, $0) }
        if let i = arrivedStores.firstIndex(of: false) { return i }
        let arrived = max(trip.count(.arrivedDropoff, order.offerId), trip.count(.delivered, order.offerId))
        return arrived < max(1, order.dropoffs) ? order.stores.count + arrived : nil
    }
}

/// The order's ⋯ menu: unassigned, cancelled, remove, and count fixes.
struct OrderOptionsMenu: View {
    @ObservedObject private var store = TripStore.shared
    let trip: Trip
    let order: Trip.Order

    var body: some View {
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
            Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundStyle(Theme.secondaryText)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Order options")
    }
}

/// "✓ Left Shake Shack · Undo" for 10 seconds after a step (or an accept), whether tapped or automatic.
struct UndoToast: View {
    @ObservedObject private var store = TripStore.shared
    let trip: Trip

    private var last: (label: String, at: Date)? {
        let step = trip.steps.max { $0.at < $1.at }.map { ($0.label, $0.at) }
        let accepted = trip.orders.max { $0.acceptedAt < $1.acceptedAt }.map { ("Accepted · " + ($0.stores.first ?? Theme.appName($0.platform)), $0.acceptedAt) }
        switch (step, accepted) {
        case let (s?, a?): return s.1 > a.1 ? s : a
        case let (s?, nil): return s
        case let (nil, a?): return a
        default: return nil
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if store.canUndo, let last, context.date.timeIntervalSince(last.at) < 10 {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark").font(.subheadline.weight(.black)).foregroundStyle(Theme.neonGreen)
                    Text(last.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button("Undo") { store.undo() }.font(.subheadline.weight(.bold)).frame(minWidth: 44, minHeight: 44)
                }
                .padding(.leading, 16).padding(.trailing, 8)
                .frame(height: 52)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
