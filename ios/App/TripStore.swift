import Foundation
import UserNotifications

/// What a trip needs from an offer: from the offer list (`LiveOffer`) or the stub on a stage-1 notification.
struct TripOfferInfo {
    let offerId: String
    let platform: String
    let payCents: Int
    let merchant: String?
    let stores: [String]
    let dropoffs: Int
    let appMilliMiles: Int?
    let confidence: Double?
    /// The refined verdict's predictions, kept on the order for "predicted vs actual".
    var predictedHourlyCents: Int? = nil
    var predictedTripMinutes: Int? = nil
    var predictedReturnMinutes: Int? = nil

    init(_ offer: LiveOffer) {
        offerId = offer.offerId ?? offer.id
        platform = offer.platform
        payCents = offer.payCents
        merchant = offer.merchant
        stores = Self.storeNames(offer.merchants, offer.merchant, offer.pickupCount)
        dropoffs = max(1, offer.dropoffCount ?? offer.orderCount ?? 1)
        appMilliMiles = offer.outboundMilliMiles
        confidence = offer.confidence
        predictedHourlyCents = offer.hourlyCents ?? Self.hourly(from: offer.notice)
        predictedTripMinutes = offer.tripMinutes ?? offer.appMinutes
        predictedReturnMinutes = offer.returnMinutes
    }

    /// "$1.16/mi · $27/hr · Accept" → 2700 (offers from before predictions were stored).
    static func hourly(from notice: String?) -> Int? {
        guard let notice, let range = notice.range(of: #"\$(\d+)/hr"#, options: .regularExpression) else { return nil }
        return Int(notice[range].dropFirst().dropLast(3)).map { $0 * 100 }
    }

    /// The capture extension's stage-1 stub: offer fields only, no addresses.
    init?(stub: [String: Any]) {
        guard let offerId = stub["offerId"] as? String, let platform = stub["platform"] as? String,
              let payCents = stub["payCents"] as? Int else { return nil }
        self.offerId = offerId
        self.platform = platform
        self.payCents = payCents
        merchant = stub["merchant"] as? String
        stores = Self.storeNames(stub["merchants"] as? [String], merchant, stub["pickupCount"] as? Int)
        dropoffs = max(1, stub["dropoffCount"] as? Int ?? 1)
        appMilliMiles = stub["outboundMilliMiles"] as? Int
        confidence = stub["confidence"] as? Double
    }

    static func storeNames(_ names: [String]?, _ merchant: String?, _ count: Int?) -> [String] {
        var list = (names ?? merchant.map { [$0] } ?? []).filter { !$0.isEmpty }
        let wanted = min(6, max(1, count ?? list.count))
        if list.count > wanted { list = Array(list.prefix(wanted)) }
        while list.count < wanted { list.append("Store \(list.count + 1)") }
        return list
    }
}

/// One run of accepted offers driven together (user, Oct 14). Stacked offers join the active trip; each order keeps
/// its own stores and drop-offs, so any interleaving works (store A, store B, drop A, drop B — or A then B).
struct Trip: Codable, Identifiable, Equatable {
    struct Order: Codable, Identifiable, Equatable {
        var id: String { offerId }
        let offerId: String
        var platform: String
        /// Pay counted in totals: the offer's pay, or what the driver entered as the real payout (tips can change it).
        var payCents: Int
        var merchant: String?
        var stores: [String]
        var dropoffs: Int
        var acceptedAt: Date
        /// nil while active; "completed", "unassigned", "cancelled by customer", … once ended.
        var ended: String?
        var endedAt: Date?
        /// The offer's pay when the driver corrected it.
        var offerPayCents: Int? = nil
        var predictedHourlyCents: Int? = nil
        var predictedTripMinutes: Int? = nil
        var predictedReturnMinutes: Int? = nil

        /// Pace including the drive back (the predicted return minutes), comparable with the verdict's $/hr.
        var paceWithReturnCents: Int? {
            guard completed, let endedAt else { return nil }
            let seconds = endedAt.timeIntervalSince(acceptedAt) + Double(predictedReturnMinutes ?? 0) * 60
            return seconds >= 300 ? Int((Double(payCents) * 3600 / seconds).rounded()) : nil
        }

        var shortName: String { stores.first ?? merchant ?? Theme.appName(platform) }
        var completed: Bool { ended == "completed" }
        var minutes: Double? { endedAt.map { $0.timeIntervalSince(acceptedAt) / 60 } }
        /// Hourly pace this order earned: pay ÷ (accepted → completed).
        var paceCents: Int? {
            guard completed, let endedAt else { return nil }
            let seconds = endedAt.timeIntervalSince(acceptedAt)
            return seconds >= 60 ? Int((Double(payCents) * 3600 / seconds).rounded()) : nil
        }
    }
    enum StepKind: String, Codable { case arrivedStore, leftStore, arrivedDropoff, delivered }
    struct Step: Codable, Equatable {
        let id: String
        let kind: StepKind
        let offerId: String
        var stop: Int
        let label: String
        let at: Date
        /// Store arrivals only: the phone's position there (a business location, for the restaurant list). Never set for
        /// drop-offs (customer locations are not stored).
        var latitude: Double? = nil
        var longitude: Double? = nil
        /// Ticked by arrival detection rather than a tap.
        var auto: Bool? = nil
    }

    let id: String
    var startedAt: Date
    var orders: [Order]
    var steps: [Step]
    var endedAt: Date?

    func has(_ kind: StepKind, _ offerId: String, _ stop: Int) -> Bool {
        steps.contains { $0.kind == kind && $0.offerId == offerId && $0.stop == stop }
    }
    func count(_ kind: StepKind, _ offerId: String) -> Int { steps.filter { $0.kind == kind && $0.offerId == offerId }.count }
    func time(_ kind: StepKind, _ offerId: String, _ stop: Int) -> Date? {
        steps.first { $0.kind == kind && $0.offerId == offerId && $0.stop == stop }?.at
    }
    var lastActivity: Date { max(steps.last?.at ?? startedAt, orders.map(\.acceptedAt).max() ?? startedAt) }

    /// Pay of orders still running or completed (unassigned/cancelled orders earn nothing we can see).
    var payCents: Int { orders.filter { $0.ended == nil || $0.completed }.reduce(0) { $0 + $1.payCents } }
    func elapsed(_ now: Date) -> TimeInterval { (endedAt ?? now).timeIntervalSince(startedAt) }
    /// Live pace: pay ÷ time since the first acceptance (the user's order timer).
    func paceCents(_ now: Date) -> Int? {
        let seconds = elapsed(now)
        return seconds >= 60 && payCents > 0 ? Int((Double(payCents) * 3600 / seconds).rounded()) : nil
    }

    /// Steps that can happen next, most likely first: leave the store you're at, finish the drop-off you're at, then
    /// arrive at the next store, then the next drop-off (an order's drop-offs open once all its stores are left).
    var actions: [TripAction] {
        var leave: [TripAction] = [], deliver: [TripAction] = [], arriveStore: [TripAction] = [], arriveDrop: [TripAction] = []
        let activeCount = orders.filter { $0.ended == nil }.count
        for order in orders where order.ended == nil {
            for (stop, store) in order.stores.enumerated() {
                if has(.arrivedStore, order.offerId, stop) {
                    if !has(.leftStore, order.offerId, stop) { leave.append(TripAction(kind: .leftStore, offerId: order.offerId, stop: stop, label: "Left \(store)")) }
                } else {
                    arriveStore.append(TripAction(kind: .arrivedStore, offerId: order.offerId, stop: stop, label: "Arrived at \(store)"))
                }
            }
            let name = { (index: Int) -> String in
                activeCount > 1 ? "drop-off (\(order.shortName)\(order.dropoffs > 1 ? " \(index + 1)/\(order.dropoffs)" : ""))"
                    : order.dropoffs > 1 ? "drop-off \(index + 1) of \(order.dropoffs)" : "drop-off"
            }
            let arrived = count(.arrivedDropoff, order.offerId), delivered = count(.delivered, order.offerId)
            let allLeft = order.stores.indices.allSatisfy { has(.leftStore, order.offerId, $0) }
            if arrived > delivered {
                deliver.append(TripAction(kind: .delivered, offerId: order.offerId, stop: delivered, label: "Delivered · \(name(delivered))"))
            } else if allLeft && arrived < order.dropoffs {
                arriveDrop.append(TripAction(kind: .arrivedDropoff, offerId: order.offerId, stop: arrived, label: "Arrived at \(name(arrived))"))
            }
        }
        return leave + deliver + arriveStore + arriveDrop
    }
}

struct TripAction: Identifiable, Equatable {
    let kind: Trip.StepKind
    let offerId: String
    let stop: Int
    let label: String
    var id: String { "\(kind.rawValue)|\(offerId)|\(stop)" }
}

/// The active trip, finished trips (for looking back at an offer), and undo. Every change also goes to the journal as
/// append-only lifecycle events (core/lifecycle.js types, source "manual"); undo writes `retracted` events. Stored in
/// the app's own container. The trip notification carries the next step as a button.
@MainActor
final class TripStore: ObservableObject {
    static let shared = TripStore()

    @Published private(set) var active: Trip?
    @Published private(set) var history: [Trip] = []
    private var undoStack: [UndoEntry] = []
    var canUndo: Bool { !undoStack.isEmpty }

    private struct UndoEntry: Codable {
        let before: Trip?
        let historyCount: Int
        let events: [EventRef]
    }
    private struct EventRef: Codable { let id: String; let offerId: String }
    private struct Saved: Codable {
        var active: Trip?
        var history: [Trip]
        var undo: [UndoEntry]
    }

    /// A trip idle this long is closed when a new offer is accepted (the driver forgot to finish it).
    private static let staleAfter: TimeInterval = 3 * 3600

    private init() {
        if PreviewData.isActive { active = PreviewData.trip; history = PreviewData.earlierDays.trips + PreviewData.pastTrips; return }
        load()
    }

    func trip(for offerId: String) -> Trip? {
        if let active, active.orders.contains(where: { $0.offerId == offerId }) { return active }
        return history.last { $0.orders.contains { $0.offerId == offerId } }
    }

    // MARK: Changes

    /// `source`: "manual" for a tap; "screen" when a delivery app's pickup screen showed the order was accepted.
    func accept(_ info: TripOfferInfo, at now: Date = Date(), source: String = "manual") {
        guard trip(for: info.offerId) == nil else { return }
        let before = active, historyCount = history.count
        var events: [[String: Any]] = []
        if var stale = active, now.timeIntervalSince(stale.lastActivity) > Self.staleAfter {
            for index in stale.orders.indices where stale.orders[index].ended == nil {
                stale.orders[index].ended = "not finished"
                stale.orders[index].endedAt = stale.lastActivity
                events.append(event("aborted_unknown", stale.orders[index].offerId, now, stale.id, ["reason": "unknown"]))
            }
            stale.endedAt = stale.lastActivity
            history.append(stale)
            active = nil
        }
        var trip = active ?? Trip(id: "trip-\(Int(now.timeIntervalSince1970))", startedAt: now, orders: [], steps: [], endedAt: nil)
        let stacked = !trip.orders.isEmpty
        trip.orders.append(Trip.Order(offerId: info.offerId, platform: info.platform, payCents: info.payCents, merchant: info.merchant,
                                      stores: info.stores, dropoffs: info.dropoffs, acceptedAt: now, ended: nil, endedAt: nil,
                                      predictedHourlyCents: info.predictedHourlyCents, predictedTripMinutes: info.predictedTripMinutes,
                                      predictedReturnMinutes: info.predictedReturnMinutes))
        var offer: [String: Any] = ["platform": info.platform, "payCents": info.payCents]
        if let merchant = info.merchant { offer["merchant"] = merchant }
        if let miles = info.appMilliMiles { offer["appMilliMiles"] = miles }
        if let confidence = info.confidence { offer["readerConfidence"] = confidence }
        events.append(event("accepted", info.offerId, now, trip.id, ["stacked": stacked, "offer": offer, "source": source,
                                                                    "confidence": source == "manual" ? 1 : 0.9,
                                                                    "stores": info.stores.count, "dropoffs": info.dropoffs]))
        active = trip
        commit(before: before, historyCount: historyCount, events: events)
        ShiftStore.shared.startIfNeeded(at: now)
        AudioCues.shared.accepted()
    }

    /// A step, tapped by the driver (`auto` false) or detected from the phone's position (`auto` true).
    /// `source` for automatic steps: "auto_location" (GPS), "screen" (seen in the delivery app), or "screen_inferred"
    /// (a step skipped on screen, filled in; low confidence so learning ignores its timing).
    func perform(_ action: TripAction, at now: Date = Date(), auto: Bool = false, source: String? = nil) {
        guard var trip = active, trip.actions.contains(action),
              let index = trip.orders.firstIndex(where: { $0.offerId == action.offerId }) else { return }
        let before = active, historyCount = history.count
        let types: [Trip.StepKind: String] = [.arrivedStore: "arrived_pickup", .leftStore: "picked_up",
                                              .arrivedDropoff: "arrived_customer", .delivered: "delivered"]
        var fields: [String: Any] = ["stop": action.stop]
        if auto {
            fields["source"] = source ?? "auto_location"
            fields["confidence"] = source == "screen_inferred" ? 0.5 : 0.9
        }
        if action.kind == .arrivedStore || action.kind == .leftStore { fields["store"] = trip.orders[index].stores[action.stop] }
        let step = event(types[action.kind]!, action.offerId, now, trip.id, fields)
        var newStep = Trip.Step(id: step["id"] as! String, kind: action.kind, offerId: action.offerId, stop: action.stop,
                                label: action.label, at: now)
        if auto { newStep.auto = true }
        if action.kind == .arrivedStore, let here = ShiftStore.shared.lastLocation,
           now.timeIntervalSince(here.timestamp) < 120, here.horizontalAccuracy <= 100 {
            newStep.latitude = here.coordinate.latitude
            newStep.longitude = here.coordinate.longitude
        }
        trip.steps.append(newStep)
        var events = [step]
        if action.kind == .delivered, trip.count(.delivered, action.offerId) >= trip.orders[index].dropoffs {
            trip.orders[index].ended = "completed"
            trip.orders[index].endedAt = now
            events.append(event("completed", action.offerId, now, trip.id, ["payCents": trip.orders[index].payCents]))
            AudioCues.shared.delivered()
        }
        finish(&trip, now, &events)
        commit(before: before, historyCount: historyCount, events: events)
    }

    enum Ending: Hashable {
        case unassigned(reason: String)
        case cancelled(by: String)
        var label: String {
            switch self {
            case .unassigned: return "unassigned"
            case .cancelled(let by): return "cancelled by " + (by == "platform" ? "the app" : by)
            }
        }
    }

    /// The order ended early (first-class outcome, addendum §2/§5); the reason only as the driver gave it.
    /// An order added by hand that's already delivered (user, Oct 15): straight into history, timed accepted → delivered.
    func recordCompleted(_ info: TripOfferInfo, acceptedAt: Date, deliveredAt: Date) {
        guard trip(for: info.offerId) == nil else { return }
        let before = active, historyCount = history.count
        let end = min(Date(), max(deliveredAt, acceptedAt.addingTimeInterval(60)))
        let order = Trip.Order(offerId: info.offerId, platform: info.platform, payCents: info.payCents, merchant: info.merchant,
                               stores: info.stores, dropoffs: info.dropoffs, acceptedAt: acceptedAt, ended: "completed", endedAt: end,
                               predictedHourlyCents: info.predictedHourlyCents, predictedTripMinutes: info.predictedTripMinutes,
                               predictedReturnMinutes: info.predictedReturnMinutes)
        let trip = Trip(id: "trip-\(Int(acceptedAt.timeIntervalSince1970))-manual", startedAt: acceptedAt, orders: [order], steps: [], endedAt: end)
        history.append(trip)
        let events = [event("accepted", info.offerId, acceptedAt, trip.id, ["source": "manual_entry", "offer": ["platform": info.platform, "payCents": info.payCents] as [String: Any]]),
                      event("completed", info.offerId, end, trip.id, ["source": "manual_entry", "payCents": info.payCents])]
        commit(before: before, historyCount: historyCount, events: events)
        ShiftStore.shared.recomputeFinals(near: acceptedAt)
        ShiftStore.shared.refreshMetrics()
    }

    func end(_ offerId: String, _ ending: Ending, at now: Date = Date()) {
        guard var trip = active, let index = trip.orders.firstIndex(where: { $0.offerId == offerId && $0.ended == nil }) else { return }
        let before = active, historyCount = history.count
        trip.orders[index].ended = ending.label
        trip.orders[index].endedAt = now
        var events: [[String: Any]]
        switch ending {
        case .unassigned(let reason): events = [event("unassigned", offerId, now, trip.id, ["reason": reason])]
        case .cancelled(let by): events = [event("cancelled", offerId, now, trip.id, ["by": by])]
        }
        finish(&trip, now, &events)
        commit(before: before, historyCount: historyCount, events: events)
    }

    /// Fix the card's counts (e.g. a second drop-off the reader missed). Not journaled as an event; the stop indexes are.
    func adjust(_ offerId: String, dropoffs delta: Int = 0, addStore: Bool = false) {
        guard var trip = active, let index = trip.orders.firstIndex(where: { $0.offerId == offerId && $0.ended == nil }) else { return }
        let before = active, historyCount = history.count
        let minimum = max(1, trip.count(.arrivedDropoff, offerId))
        trip.orders[index].dropoffs = min(8, max(minimum, trip.orders[index].dropoffs + delta))
        if addStore, trip.orders[index].stores.count < 6 { trip.orders[index].stores.append("Store \(trip.orders[index].stores.count + 1)") }
        active = trip
        commit(before: before, historyCount: historyCount, events: [])
    }

    func undo(at now: Date = Date()) {
        guard let entry = undoStack.popLast() else { return }
        active = entry.before
        if history.count > entry.historyCount { history.removeLast(history.count - entry.historyCount) }
        let tripId = entry.before?.id ?? "trip"
        OfferJournal.appendEvents(entry.events.map { event("retracted", $0.offerId, now, tripId, ["target": $0.id]) })
        save()
        TripNotifier.update(active)
    }

    /// Ends the trip when every order has ended; the driver is free for offers again.
    private func finish(_ trip: inout Trip, _ now: Date, _ events: inout [[String: Any]]) {
        if trip.orders.allSatisfy({ $0.ended != nil }) {
            trip.endedAt = now
            for order in trip.orders { events.append(event("available_again", order.offerId, now, trip.id)) }
            history.append(trip)
            if history.count > 2000 { history.removeFirst(history.count - 2000) }
            active = nil
            ShiftStore.shared.tripEnded()
        } else {
            active = trip
        }
    }

    private func commit(before: Trip?, historyCount: Int, events: [[String: Any]]) {
        undoStack.append(UndoEntry(before: before, historyCount: historyCount,
                                   events: events.compactMap { e in (e["id"] as? String).map { EventRef(id: $0, offerId: e["offerId"] as? String ?? "") } }))
        if undoStack.count > 20 { undoStack.removeFirst(undoStack.count - 20) }
        if !events.isEmpty { OfferJournal.appendEvents(events) }
        save()
        TripNotifier.update(active)
    }

    // MARK: Journal events and storage

    private static let localFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    private func event(_ type: String, _ offerId: String, _ at: Date, _ tripId: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        let stop = (fields["stop"] as? Int).map { ":s\($0)" } ?? ""
        var e: [String: Any] = ["v": 2, "id": "\(offerId):\(type)\(stop):\(Int(at.timeIntervalSince1970 * 1000))", "type": type,
                                "offerId": offerId, "at": Self.localFormatter.string(from: at), "source": "manual",
                                "confidence": 1, "tripId": tripId]
        for (key, value) in fields { e[key] = value }
        return e
    }

    private var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("trips.json")
    }

    /// The real payout of a completed order (tips can change it). Totals use it; the offer's pay is kept.
    func adjustPay(_ offerId: String, cents: Int, at now: Date = Date()) {
        func apply(_ trip: inout Trip) -> Bool {
            guard let index = trip.orders.firstIndex(where: { $0.offerId == offerId }) else { return false }
            if trip.orders[index].offerPayCents == nil { trip.orders[index].offerPayCents = trip.orders[index].payCents }
            trip.orders[index].payCents = max(0, cents)
            OfferJournal.appendEvents([event("pay_adjusted", offerId, now, trip.id, ["payCents": max(0, cents)])])
            return true
        }
        if var trip = active, apply(&trip) { active = trip }
        else if let index = history.lastIndex(where: { $0.orders.contains { $0.offerId == offerId } }) {
            var trip = history[index]
            if apply(&trip) { history[index] = trip }
            ShiftStore.shared.recomputeFinals(near: trip.startedAt)
        }
        save()
    }

    /// Corrects or completes an order by hand (user, Oct 15: edit a finished order's times and pay; Oct 18: edit the
    /// current order's pickups, drop-offs, and stores). `storeEdits`: the pickups in their new order, each with its
    /// index in the saved order (nil = added); removed pickups lose their store steps and the rest are renumbered.
    /// `dropoffs` never goes below those already reached; set to the number delivered, an order in progress completes.
    /// Edits to the current order can be undone; the trip ends if the edit finished its last order.
    func editOrder(_ offerId: String, platform: String, payCents: Int, ended: String?, acceptedAt: Date, endedAt: Date?,
                   storeEdits: [(from: Int?, name: String)], dropoffs: Int, at now: Date = Date()) {
        let names = storeEdits.enumerated().map { index, edit -> String in
            let name = edit.name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "Store \(index + 1)" : name
        }
        guard !names.isEmpty else { return }
        var newIndex: [Int: Int] = [:]
        for (index, edit) in storeEdits.enumerated() { if let from = edit.from { newIndex[from] = index } }
        func apply(_ trip: inout Trip) -> Bool {
            guard let index = trip.orders.firstIndex(where: { $0.offerId == offerId }) else { return false }
            var order = trip.orders[index]
            if order.payCents != payCents {
                if order.offerPayCents == nil { order.offerPayCents = order.payCents }
                order.payCents = max(0, payCents)
            }
            order.platform = platform
            order.acceptedAt = min(acceptedAt, now)
            if let ended, order.ended != nil {
                order.ended = ended
                order.endedAt = min(now, max(endedAt ?? order.acceptedAt, order.acceptedAt.addingTimeInterval(60)))
            }
            trip.steps = trip.steps.compactMap { step in
                guard step.offerId == offerId, step.kind == .arrivedStore || step.kind == .leftStore else { return step }
                guard let moved = newIndex[step.stop] else { return nil }
                var step = step
                step.stop = moved
                return step
            }
            order.stores = names
            order.merchant = names.first
            let delivered = trip.count(.delivered, offerId)
            order.dropoffs = max(dropoffs, 1, trip.count(.arrivedDropoff, offerId), delivered)
            if order.ended == nil, delivered >= order.dropoffs {
                order.ended = "completed"
                order.endedAt = trip.steps.filter { $0.offerId == offerId && $0.kind == .delivered }.map(\.at).max() ?? now
            }
            trip.orders[index] = order
            trip.startedAt = min(trip.orders.map(\.acceptedAt).min() ?? trip.startedAt, trip.steps.map(\.at).min() ?? .distantFuture)
            if trip.endedAt != nil {
                trip.endedAt = max(trip.orders.compactMap(\.endedAt).max() ?? trip.startedAt, trip.steps.map(\.at).max() ?? .distantPast)
            }
            var fields: [String: Any] = ["payCents": order.payCents, "platform": platform, "stores": names.count, "dropoffs": order.dropoffs,
                                         "acceptedAt": Self.localFormatter.string(from: order.acceptedAt)]
            if let endedAt = order.endedAt { fields["endedAt"] = Self.localFormatter.string(from: endedAt) }
            if let outcome = order.ended { fields["ended"] = outcome }
            OfferJournal.appendEvents([event("order_edited", offerId, now, trip.id, fields)])
            return true
        }
        if var trip = active, trip.orders.contains(where: { $0.offerId == offerId }) {
            let before = active, historyCount = history.count
            guard apply(&trip) else { return }
            var events: [[String: Any]] = []
            finish(&trip, now, &events)
            commit(before: before, historyCount: historyCount, events: events)
        } else if let index = history.lastIndex(where: { $0.orders.contains { $0.offerId == offerId } }) {
            var trip = history[index]
            if apply(&trip) { history[index] = trip }
            ShiftStore.shared.recomputeFinals(near: trip.startedAt)
            save()
        }
        ShiftStore.shared.refreshMetrics()
    }

    /// Removes an order (a mistaken accept, or one the driver doesn't want in their history): its steps go too, and a
    /// trip left empty is removed. The journal keeps a "deleted" event so learning ignores the order. On the active trip
    /// this can be undone.
    func deleteOrder(_ offerId: String, at now: Date = Date()) {
        func strip(_ trip: Trip) -> Trip? {
            var t = trip
            t.orders.removeAll { $0.offerId == offerId }
            t.steps.removeAll { $0.offerId == offerId }
            return t.orders.isEmpty ? nil : t
        }
        if let trip = active, trip.orders.contains(where: { $0.offerId == offerId }) {
            let before = active, historyCount = history.count
            var events = [event("deleted", offerId, now, trip.id)]
            if var remaining = strip(trip) { finish(&remaining, now, &events) } else { active = nil }
            commit(before: before, historyCount: historyCount, events: events)
            return
        }
        guard let index = history.firstIndex(where: { $0.orders.contains { $0.offerId == offerId } }) else { return }
        let trip = history[index]
        if let remaining = strip(trip) { history[index] = remaining } else { history.remove(at: index) }
        OfferJournal.appendEvents([event("deleted", offerId, now, trip.id)])
        save()
        ShiftStore.shared.recomputeFinals(near: trip.startedAt)
    }

    // MARK: Backup restore and demo data

    /// Adds finished trips that aren't here yet (restore from a backup, or demo data). Returns how many were added.
    @discardableResult
    func importTrips(_ trips: [Trip]) -> Int {
        let known = Set(history.map(\.id) + [active?.id].compactMap { $0 })
        let added = trips.filter { !known.contains($0.id) && $0.endedAt != nil }
        guard !added.isEmpty else { return 0 }
        history = (history + added).sorted { $0.startedAt < $1.startedAt }
        save()
        return added.count
    }

    func removeTrips(where test: (Trip) -> Bool) {
        history.removeAll(where: test)
        undoStack.removeAll()
        save()
    }

    private func load() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(Saved.self, from: data) else { return }
        active = saved.active
        history = saved.history
        undoStack = saved.undo
    }

    private func save() {
        guard !PreviewData.isActive, let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Saved(active: active, history: history, undo: undoStack)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Notification buttons

    /// Handles a button on an offer or trip notification (the app may have been launched in the background for it).
    func handle(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        switch actionIdentifier {
        case NotificationActions.accept:
            if let offer = LiveOfferStorage.fromNotification(userInfo) {
                accept(TripOfferInfo(offer))
            } else if let text = userInfo["offerStub"] as? String, let data = text.data(using: .utf8),
                      let stub = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let info = TripOfferInfo(stub: stub) {
                accept(info)
            }
        case NotificationActions.next:
            // Only the step the notification showed; if the trip moved on in the app meanwhile, just refresh it.
            if let id = userInfo["tripAction"] as? String, let action = active?.actions.first(where: { $0.id == id }) {
                perform(action)
            } else {
                TripNotifier.update(active)
            }
        case NotificationActions.undo:
            undo()
        default:
            break
        }
    }
}

/// The quiet trip notification (no banner or sound): next step as a button, plus Undo.
/// Shown only when the Live Activity can't be (not started yet because the app was closed, or Live Activities off).
@MainActor
enum TripNotifier {
    nonisolated static let identifier = "trip"

    static func update(_ trip: Trip?) {
        let center = UNUserNotificationCenter.current()
        guard !PreviewData.isActive else { return }
        let live = TripActivityController.update(trip)
        guard let trip, let next = trip.actions.first, !live else {
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return
        }
        let content = UNMutableNotificationContent()
        let pay = (Double(trip.payCents) / 100).formatted(.currency(code: "USD"))
        content.title = "On a trip · \(trip.orders.filter { $0.ended == nil }.count) order(s) · \(pay)"
        content.body = "Next: \(next.label) · started \(trip.startedAt.formatted(date: .omitted, time: .shortened))"
        content.categoryIdentifier = NotificationActions.tripCategory(next.kind.rawValue)
        content.threadIdentifier = "trip"
        content.interruptionLevel = .passive
        content.userInfo = ["tripAction": next.id]
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
