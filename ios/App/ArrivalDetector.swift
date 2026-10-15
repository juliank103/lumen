import Foundation
import CoreLocation
import MapKit

/// Ticks trip steps from the phone's position (review item: fewer taps). Pure logic, fed one location at a time:
/// - Arrived at a store: within 120 m of the store's known spot for 20 s (not just passing or at a red light).
/// - Left a store: more than 200 m from where the arrival was ticked (or the store's spot).
/// - Arrived at a drop-off: once all of that order's stores are left, stopped (within 40 m) for 75 s, at least 400 m
///   from the stores.
/// - Delivered: moving again, more than 150 m from where the drop-off arrival happened.
/// The drop-off spot is held in memory only, never stored. The same step never fires twice within 10 minutes, so an
/// Undo isn't immediately repeated.
struct ArrivalDetector {
    static let storeRadius: CLLocationDistance = 120
    static let storeSeconds: TimeInterval = 20
    static let leftStoreDistance: CLLocationDistance = 200
    static let dwellRadius: CLLocationDistance = 40
    static let dwellSeconds: TimeInterval = 75
    static let dropoffMinFromStore: CLLocationDistance = 400
    static let deliveredDistance: CLLocationDistance = 150

    private var dwellCenter: CLLocation?
    private var dwellSince: Date?
    private var dropoffSpots: [String: CLLocation] = [:]  // action id of the pending "Delivered" → where the driver stopped
    private var fired: [String: Date] = [:]
    private var nearStoreSince: [String: Date] = [:]

    /// The step the position shows has happened, if any. `storeSpots`: action id of each pending store arrival → the
    /// store's location (known restaurant or Apple Maps search).
    mutating func next(at location: CLLocation, trip: Trip, storeSpots: [String: CLLocation]) -> TripAction? {
        let now = location.timestamp
        fired = fired.filter { now.timeIntervalSince($0.value) < 600 }
        trackDwell(location)
        let actions = trip.actions.filter { fired[$0.id] == nil }

        // Leaving a store.
        for action in actions where action.kind == .leftStore {
            let spot = arrivalSpot(trip, action) ?? storeSpots[TripAction(kind: .arrivedStore, offerId: action.offerId, stop: action.stop, label: "").id]
            if let spot, location.distance(from: spot) > Self.leftStoreDistance { return fire(action, now) }
        }
        // Moving away from a drop-off.
        for action in actions where action.kind == .delivered {
            let key = action.id
            if dropoffSpots[key] == nil { dropoffSpots[key] = dwellCenter ?? location }
            if let spot = dropoffSpots[key], location.distance(from: spot) > Self.deliveredDistance, location.speed > 2 {
                dropoffSpots[key] = nil
                return fire(action, now)
            }
        }
        // Reaching a store.
        for action in actions where action.kind == .arrivedStore {
            guard let spot = storeSpots[action.id], location.distance(from: spot) <= Self.storeRadius else {
                nearStoreSince[action.id] = nil
                continue
            }
            let since = nearStoreSince[action.id] ?? now
            nearStoreSince[action.id] = since
            if now.timeIntervalSince(since) >= Self.storeSeconds {
                nearStoreSince[action.id] = nil
                return fire(action, now)
            }
        }
        // Stopping at a drop-off.
        if let since = dwellSince, now.timeIntervalSince(since) >= Self.dwellSeconds, let center = dwellCenter {
            for action in actions where action.kind == .arrivedDropoff {
                let stores = storeLocations(trip, action.offerId, storeSpots)
                if stores.allSatisfy({ center.distance(from: $0) >= Self.dropoffMinFromStore }) {
                    let delivered = TripAction(kind: .delivered, offerId: action.offerId, stop: action.stop, label: "")
                    dropoffSpots[delivered.id] = center
                    return fire(action, now)
                }
            }
        }
        return nil
    }

    private mutating func trackDwell(_ location: CLLocation) {
        if let center = dwellCenter, location.distance(from: center) <= Self.dwellRadius { return }
        dwellCenter = location
        dwellSince = location.timestamp
    }

    private mutating func fire(_ action: TripAction, _ now: Date) -> TripAction {
        fired[action.id] = now
        dwellSince = now // A new dwell must start after this step.
        return action
    }

    private func arrivalSpot(_ trip: Trip, _ action: TripAction) -> CLLocation? {
        guard let step = trip.steps.first(where: { $0.kind == .arrivedStore && $0.offerId == action.offerId && $0.stop == action.stop }),
              let lat = step.latitude, let lon = step.longitude else { return nil }
        return CLLocation(latitude: lat, longitude: lon)
    }

    private func storeLocations(_ trip: Trip, _ offerId: String, _ storeSpots: [String: CLLocation]) -> [CLLocation] {
        guard let order = trip.orders.first(where: { $0.offerId == offerId }) else { return [] }
        return order.stores.indices.compactMap { stop in
            arrivalSpot(trip, TripAction(kind: .leftStore, offerId: offerId, stop: stop, label: ""))
                ?? storeSpots[TripAction(kind: .arrivedStore, offerId: offerId, stop: stop, label: "").id]
        }
    }
}

/// Runs the detector on the shift's location updates and finds store spots: a restaurant's saved location (from past
/// arrivals), else the nearest Apple Maps match for the store's name around the phone (searched once per store).
@MainActor
final class AutoSteps {
    static let shared = AutoSteps()
    static let enabledKey = "autoDetectSteps"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private var detector = ArrivalDetector()
    private var searched: [String: CLLocation?] = [:]   // store name (lowercased) → search result

    func update(_ location: CLLocation) {
        guard Self.isEnabled, let trip = TripStore.shared.active, location.horizontalAccuracy <= 65 else { return }
        var spots: [String: CLLocation] = [:]
        for action in trip.actions where action.kind == .arrivedStore {
            guard let order = trip.orders.first(where: { $0.offerId == action.offerId }), action.stop < order.stores.count else { continue }
            if let spot = spot(for: order.stores[action.stop], near: location) { spots[action.id] = spot }
        }
        if let action = detector.next(at: location, trip: trip, storeSpots: spots) {
            TripStore.shared.perform(action, at: location.timestamp, auto: true)
        }
    }

    private func spot(for store: String, near here: CLLocation) -> CLLocation? {
        let key = Self.normalize(store)
        guard !key.isEmpty, !key.hasPrefix("store ") else { return nil }
        // A restaurant Lumen has a location for (saved from earlier arrivals), the closest branch with that name.
        let known = RestaurantStore.shared.restaurants.filter { r in r.lat != nil && r.aliases.contains { Self.normalize($0) == key } }
            .compactMap { r in r.lat.flatMap { lat in r.lon.map { CLLocation(latitude: lat, longitude: $0) } } }
            .min { $0.distance(from: here) < $1.distance(from: here) }
        if let known, known.distance(from: here) < 25_000 { return known }
        if let cached = searched[key] { return cached }
        searched[key] = .some(nil) // Searching; don't start again.
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = store
        request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        request.resultTypes = .pointOfInterest
        MKLocalSearch(request: request).start { response, _ in
            let best = response?.mapItems.map { CLLocation(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude) }
                .filter { $0.distance(from: here) < 25_000 }
                .min { $0.distance(from: here) < $1.distance(from: here) }
            MainActor.assumeIsolated { AutoSteps.shared.searched[key] = .some(best) }
        }
        return nil
    }

    static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"['’`]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
