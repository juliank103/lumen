import Foundation
import MapKit
import CoreLocation

/// Road distance and drive time back to the return destination (__HOME_NAME__ unless changed in the app) with Apple Maps. A lookup sends Apple only what the offer card
/// shows (the Uber drop-off cross-street and town, the restaurant's street address, town names on the map) or the
/// phone's position. Nothing is stored; results are cached in memory for the broadcast session. Work runs on the
/// main queue and completions are called there.
final class ReturnRouter: NSObject, CLLocationManagerDelegate {
    struct Route {
        let kind: String
        let milliMiles: Int
        /// Position error of a map-read drop-off ("map" routes only).
        var uncertaintyMilliMiles: Int? = nil
        /// Apple Maps drive time of the return, when the return was routed exactly.
        var returnMinutes: Int? = nil
        /// The drive from the driver's position back to __HOME_NAME__, already planned (user's rule: always return there).
        var creditMilliMiles: Int? = nil
        var creditMinutes: Int? = nil
        /// Apple Maps drive time here → pickup → drop-offs, for cards that show no time.
        var tripDriveMinutes: Int? = nil
    }
    /// One road route: meters and seconds.
    struct Leg { let meters: CLLocationDistance; let seconds: TimeInterval }

    // Searches (map town labels, addresses) are biased toward where the driver is, so the tool works in any zone:
    // the phone's position, else the chosen return destination, else Fairview (the original zone).
    private static let homeArea = CLLocationCoordinate2D(latitude: __AREA_LAT__, longitude: __AREA_LON__)
    private var searchCenter: CLLocationCoordinate2D {
        if let fix = phoneFix { return CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon) }
        let destination = homeDestination ?? ReturnDestinationStore.current
        if let latitude = destination.latitude, let longitude = destination.longitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return Self.homeArea
    }
    private var area: MKCoordinateRegion {
        MKCoordinateRegion(center: searchCenter, latitudinalMeters: 150_000, longitudinalMeters: 150_000)
    }
    /// Town lookups are cached per label and rough zone (~35 mi), so "Franklin" here is not reused elsewhere.
    private func townKey(_ label: String) -> String {
        let center = searchCenter
        return String(format: "%@|%.0f,%.0f", label, center.latitude * 2, center.longitude * 2)
    }
    private let nameLock = NSLock()
    private var resolvedHomeName: String?
    /// What the return destination resolved to (Apple Maps' name for the default); readable from any queue.
    var homeName: String? {
        nameLock.lock(); defer { nameLock.unlock() }
        return resolvedHomeName
    }
    private var home: MKMapItem?
    /// The destination `home` was resolved for; a different choice in the app resolves again.
    private var homeDestination: ReturnDestination?
    /// The destination's name for messages.
    private var destinationName: String { homeDestination?.name ?? ReturnDestinationStore.current.name }
    private var legs: [String: Leg] = [:]
    private var towns: [String: (Double, Double)?] = [:]
    private var location: CLLocationManager?
    private var latestFix: CLLocation?

    static func milliMiles(_ meters: CLLocationDistance) -> Int { Int((meters / 1.609344).rounded()) }
    static func minutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded()) }

    // MARK: Position

    /// Starts location updates for the broadcast. Works only if iOS lets the extension use the app's permission.
    func startLocation() {
        DispatchQueue.main.async {
            guard self.location == nil else { return }
            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
            manager.startUpdatingLocation()
            self.location = manager
        }
    }

    func stopLocation() {
        DispatchQueue.main.async { self.location?.stopUpdatingLocation(); self.location = nil }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let fix = locations.last, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy < 500 {
            latestFix = fix
            fixLock.lock(); lastPhoneFix = (fix.coordinate.latitude, fix.coordinate.longitude, fix.timestamp); fixLock.unlock()
        }
    }

    private let fixLock = NSLock()
    private var lastPhoneFix: (lat: Double, lon: Double, at: Date)?
    /// The phone's own position if fresh (≤ 3 min), readable from any queue: anchors the map's driver dot.
    var phoneFix: (lat: Double, lon: Double)? {
        fixLock.lock(); defer { fixLock.unlock() }
        guard let fix = lastPhoneFix, Date().timeIntervalSince(fix.at) < 180 else { return nil }
        return (fix.lat, fix.lon)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    /// A fresh phone fix, else the driver dot read off the offer map.
    private func currentPosition(mapCurrent: (Double, Double)?) -> (coordinate: CLLocationCoordinate2D, source: String)? {
        if let fix = latestFix ?? location?.location, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy < 500,
           Date().timeIntervalSince(fix.timestamp) < 180 {
            return (fix.coordinate, "phone location")
        }
        if let mapCurrent { return (CLLocationCoordinate2D(latitude: mapCurrent.0, longitude: mapCurrent.1), "map dot") }
        return nil
    }

    /// The drive from here back to __HOME_NAME__ (the "already planned" credit). Nil when unknown or already there.
    func credit(mapCurrent: (Double, Double)?, completion: @escaping (Leg?, String) -> Void) {
        DispatchQueue.main.async {
            guard let here = self.currentPosition(mapCurrent: mapCurrent) else { return completion(nil, "position unknown") }
            self.resolveHome { home in
                guard let home else { return completion(nil, "\(self.destinationName) not found") }
                self.route(from: MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate)), to: home) { leg in
                    guard let leg else { return completion(nil, "no route from \(here.source)") }
                    let atHome = leg.meters < 480
                    self.remember(credit: atHome ? (0, 0) : (Self.milliMiles(leg.meters), Self.minutes(leg.seconds)))
                    completion(atHome ? nil : leg, atHome ? "at \(self.destinationName)" : "from \(here.source)")
                }
            }
        }
    }

    // The last drive-back measurement, for the stage-1 verdict of the next offer (valid 3 minutes).
    private let creditLock = NSLock()
    private var lastCredit: (milliMiles: Int, minutes: Int, at: Date)?
    private func remember(credit: (Int, Int)) {
        creditLock.lock(); lastCredit = (credit.0, credit.1, Date()); creditLock.unlock()
    }
    /// Readable from any queue. (0, 0) means at __HOME_NAME__; nil means position not measured recently.
    var recentCredit: (milliMiles: Int, minutes: Int)? {
        creditLock.lock(); defer { creditLock.unlock() }
        guard let c = lastCredit, Date().timeIntervalSince(c.at) < 180 else { return nil }
        return (c.milliMiles, c.minutes)
    }

    /// Measure the drive back now (at broadcast start and after each offer), so stage 1 has a fresh value.
    func refreshCredit() { credit(mapCurrent: nil) { _, _ in } }

    /// Drive time for the trip itself: here → pickup → drop-offs (nearest first). Nil if any leg can't be routed.
    func tripDrive(mapCurrent: (Double, Double)?, pickup: (Double, Double)?, dropoffs: [(latitude: Double, longitude: Double)],
                   completion: @escaping (TimeInterval?) -> Void) {
        DispatchQueue.main.async {
            guard let here = self.currentPosition(mapCurrent: mapCurrent), let pickup, !dropoffs.isEmpty else { return completion(nil) }
            let item = { (lat: Double, lon: Double) in MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))) }
            // Visit drop-offs nearest-first from the pickup (the app's real order is not shown).
            var stops: [(Double, Double)] = [(here.coordinate.latitude, here.coordinate.longitude), pickup]
            var remaining = dropoffs.map { ($0.latitude, $0.longitude) }
            while !remaining.isEmpty {
                let last = stops[stops.count - 1]
                let next = remaining.enumerated().min { hypot($0.element.0 - last.0, $0.element.1 - last.1) < hypot($1.element.0 - last.0, $1.element.1 - last.1) }!
                stops.append(next.element)
                remaining.remove(at: next.offset)
            }
            var total: TimeInterval = 0
            func leg(_ index: Int) {
                guard index + 1 < stops.count else { return completion(total) }
                self.route(from: item(stops[index].0, stops[index].1), to: item(stops[index + 1].0, stops[index + 1].1)) { result in
                    guard let result else { return completion(nil) }
                    total += result.seconds
                    leg(index + 1)
                }
            }
            leg(0)
        }
    }

    /// Road meters store -> drop-offs (nearest-first) and, when the position is known, here -> store; for checking the
    /// map-read drop-offs against the app's own trip miles (user, Oct 21).
    func tripDistance(mapCurrent: (Double, Double)?, pickup: (Double, Double)?, dropoffs: [(latitude: Double, longitude: Double)],
                      completion: @escaping (_ toPickup: CLLocationDistance?, _ delivery: CLLocationDistance?) -> Void) {
        DispatchQueue.main.async {
            guard let pickup, !dropoffs.isEmpty else { return completion(nil, nil) }
            let item = { (lat: Double, lon: Double) in MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))) }
            var stops: [(Double, Double)] = [pickup]
            var remaining = dropoffs.map { ($0.latitude, $0.longitude) }
            while !remaining.isEmpty {
                let last = stops[stops.count - 1]
                let next = remaining.enumerated().min { hypot($0.element.0 - last.0, $0.element.1 - last.1) < hypot($1.element.0 - last.0, $1.element.1 - last.1) }!
                stops.append(next.element)
                remaining.remove(at: next.offset)
            }
            var delivery: CLLocationDistance = 0
            func leg(_ index: Int) {
                guard index + 1 < stops.count else {
                    guard let here = self.currentPosition(mapCurrent: mapCurrent) else { return completion(nil, delivery) }
                    return self.route(from: item(here.coordinate.latitude, here.coordinate.longitude), to: item(pickup.0, pickup.1)) { toPickup in
                        completion(toPickup?.meters, delivery)
                    }
                }
                self.route(from: item(stops[index].0, stops[index].1), to: item(stops[index + 1].0, stops[index + 1].1)) { result in
                    guard let result else { return completion(nil, nil) }
                    delivery += result.meters
                    leg(index + 1)
                }
            }
            leg(0)
        }
    }

    // MARK: Return from card text and bounds

    func estimate(dropoff: String?, pickup: String?, outboundMilliMiles: Int?, completion: @escaping (Route?, String?) -> Void) {
        DispatchQueue.main.async {
            self.resolveHome { home in
                guard let home else { return completion(nil, "\(self.destinationName) not found in Apple Maps") }
                self.fromDropoff(dropoff, home: home) { route in
                    if let route { return completion(route, nil) }
                    guard let outboundMilliMiles else { return completion(nil, "Order miles not read") }
                    // The drop-off lies on the app's route, so return ≤ (any point on the route)→__HOME_NAME__ + trip miles.
                    self.boundFromPickup(pickup, home: home, outbound: outboundMilliMiles) { route in
                        if let route { return completion(route, nil) }
                        self.boundFromHere(home: home, outbound: outboundMilliMiles) { route in
                            if let route { return completion(route, nil) }
                            completion(nil, dropoff != nil ? "Drop-off not found in Apple Maps; current location unavailable"
                                       : "No drop-off or restaurant address on the card; current location unavailable")
                        }
                    }
                }
            }
        }
    }

    private func fromDropoff(_ dropoff: String?, home: MKMapItem, completion: @escaping (Route?) -> Void) {
        guard let dropoff else { return completion(nil) }
        legToHome(from: dropoff, home: home) { leg, streetLevel in
            if let leg {
                return completion(Route(kind: streetLevel ? "dropoff" : "dropoff_town", milliMiles: Self.milliMiles(leg.meters),
                                        returnMinutes: Self.minutes(leg.seconds)))
            }
            // Fall back to the town alone ("Roman Ln, Springfield" → "Springfield").
            guard let town = dropoff.split(separator: ",").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
                  !town.isEmpty, town != dropoff else { return completion(nil) }
            self.legToHome(from: town, home: home) { leg, _ in
                completion(leg.map { Route(kind: "dropoff_town", milliMiles: Self.milliMiles($0.meters), returnMinutes: Self.minutes($0.seconds)) })
            }
        }
    }

    private func boundFromPickup(_ pickup: String?, home: MKMapItem, outbound: Int, completion: @escaping (Route?) -> Void) {
        guard let pickup else { return completion(nil) }
        legToHome(from: pickup, home: home) { leg, streetLevel in
            guard let leg, streetLevel else { return completion(nil) }
            completion(Route(kind: "worst_case", milliMiles: Self.milliMiles(leg.meters) + outbound))
        }
    }

    /// The driver's position starts the app's route.
    private func boundFromHere(home: MKMapItem, outbound: Int, completion: @escaping (Route?) -> Void) {
        guard let here = currentPosition(mapCurrent: nil) else { return completion(nil) }
        route(from: MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate)), to: home) { leg in
            completion(leg.map { Route(kind: "worst_case", milliMiles: Self.milliMiles($0.meters) + outbound) })
        }
    }

    // MARK: Return from the offer map

    /// Town names printed on the offer map → coordinates (exact town matches only), plus the restaurant's
    /// coordinate when its street address is known.
    /// Whether the last map's store position came from your own visits (for the trace).
    private(set) var pickupFromVisits = false

    func mapPlaces(labels: [String], pickup: String?, pickupName: String? = nil,
                   completion: @escaping ([String: (Double, Double)], (Double, Double)?) -> Void) {
        DispatchQueue.main.async {
            let group = DispatchGroup()
            var places: [String: (Double, Double)] = [:]
            var pickupPlace: (Double, Double)?
            for label in labels {
                let key = self.townKey(label)
                if let cached = self.towns[key] {
                    if let coordinate = cached { places[label] = coordinate }
                    continue
                }
                group.enter()
                self.searchTown(label) { coordinate in
                    self.towns.updateValue(coordinate, forKey: key)
                    if let coordinate { places[label] = coordinate }
                    group.leave()
                }
            }
            // A store you've arrived at before: its real position (reader upgrade 3, Oct 23) beats any search.
            let near = self.currentPosition(mapCurrent: nil).map { CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            if let name = pickupName, let known = StorePlaces.nearest(name, near: near) {
                pickupPlace = known
                self.pickupFromVisits = true
            } else if let pickup {
                self.pickupFromVisits = false
                group.enter()
                self.search(pickup) { item in
                    if let item, item.placemark.thoroughfare != nil {
                        pickupPlace = (item.placemark.coordinate.latitude, item.placemark.coordinate.longitude)
                    }
                    group.leave()
                }
            } else if let pickupName, let here = self.currentPosition(mapCurrent: nil) {
                self.pickupFromVisits = false
                // No address on the card: the branch nearest the driver (offers are local). The map reader then checks
                // that a pin really sits in that direction and distance before trusting it.
                group.enter()
                self.searchNearest(pickupName, around: here.coordinate) { coordinate in
                    pickupPlace = coordinate
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(places, pickupPlace) }
        }
    }

    /// The longest road route from any of the map-read drop-offs to __HOME_NAME__ (the final stop is one of them).
    func longestReturn(from dropoffs: [(latitude: Double, longitude: Double)], completion: @escaping (Leg?) -> Void) {
        DispatchQueue.main.async {
            self.resolveHome { home in
                guard let home, !dropoffs.isEmpty else { return completion(nil) }
                let group = DispatchGroup()
                var found: [Leg] = []
                var failed = false
                for point in dropoffs {
                    group.enter()
                    let source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)))
                    self.route(from: source, to: home) { leg in
                        if let leg { found.append(leg) } else { failed = true }
                        group.leave()
                    }
                }
                // A missing route could be the longest one, so any failure means no answer.
                group.notify(queue: .main) { completion(failed ? nil : found.max { $0.meters < $1.meters }) }
            }
        }
    }

    // MARK: Apple Maps

    private var nearestCache: [String: (Double, Double)?] = [:]

    /// The point of interest with this name closest to `around` (within 25 km), cached per name and rough position.
    private func searchNearest(_ name: String, around: CLLocationCoordinate2D, completion: @escaping ((Double, Double)?) -> Void) {
        let key = String(format: "%@|%.2f,%.2f", name.lowercased(), around.latitude, around.longitude)
        if let cached = nearestCache[key] { return completion(cached) }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name.replacingOccurrences(of: "&", with: "and")
        request.region = MKCoordinateRegion(center: around, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        request.resultTypes = .pointOfInterest
        MKLocalSearch(request: request).start { response, _ in
            let here = CLLocation(latitude: around.latitude, longitude: around.longitude)
            let best = response?.mapItems
                .map { ($0, here.distance(from: CLLocation(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude))) }
                .filter { $0.1 < 25_000 }
                .min { $0.1 < $1.1 }
            let coordinate = best.map { ($0.0.placemark.coordinate.latitude, $0.0.placemark.coordinate.longitude) }
            self.nearestCache.updateValue(coordinate, forKey: key)
            completion(coordinate)
        }
    }

    private func searchTown(_ name: String, completion: @escaping ((Double, Double)?) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.region = area
        request.resultTypes = .address
        let center = CLLocation(latitude: searchCenter.latitude, longitude: searchCenter.longitude)
        MKLocalSearch(request: request).start { response, _ in
            // Only a town near here: a map shows the area around the offer (Oct 24: "Reading" matched a far-away town).
            let match = response?.mapItems.first { item in
                [item.placemark.locality, item.name].compactMap { $0 }.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                    && (item.placemark.location.map { $0.distance(from: center) <= 65_000 } ?? false)
            }
            completion(match.map { ($0.placemark.coordinate.latitude, $0.placemark.coordinate.longitude) })
        }
    }

    /// The return destination chosen in the app (read on every lookup, so a change applies from the next offer).
    func resolveHome(_ completion: @escaping (MKMapItem?) -> Void) {
        let wanted = ReturnDestinationStore.current
        if let home, homeDestination == wanted { return completion(home) }
        if homeDestination != nil, homeDestination != wanted {
            // The drive-back credit was measured to the old destination.
            creditLock.lock(); lastCredit = nil; creditLock.unlock()
        }
        let finish = { (item: MKMapItem?, name: String?) in
            self.home = item
            self.homeDestination = item == nil ? nil : wanted
            self.nameLock.lock(); self.resolvedHomeName = name; self.nameLock.unlock()
            completion(item)
        }
        if let latitude = wanted.latitude, let longitude = wanted.longitude {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
            item.name = wanted.name
            return finish(item, wanted.name)
        }
        search(wanted.query ?? wanted.name) { item in
            finish(item, item.map { [$0.name, $0.placemark.locality].compactMap { $0 }.joined(separator: ", ") })
        }
    }

    private func search(_ query: String, completion: @escaping (MKMapItem?) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query.replacingOccurrences(of: "&", with: "and")
        request.region = area
        MKLocalSearch(request: request).start { response, _ in completion(response?.mapItems.first) }
    }

    /// Road leg to __HOME_NAME__, and whether the start was found at street level (not just a town).
    private func legToHome(from query: String, home: MKMapItem, completion: @escaping (Leg?, Bool) -> Void) {
        search(query) { item in
            guard let item else { return completion(nil, false) }
            let streetLevel = item.placemark.thoroughfare != nil
            self.route(from: item, to: home) { leg in completion(leg, streetLevel) }
        }
    }

    private func route(from source: MKMapItem, to destination: MKMapItem, completion: @escaping (Leg?) -> Void) {
        let a = source.placemark.coordinate, b = destination.placemark.coordinate
        let key = String(format: "%.4f,%.4f>%.4f,%.4f", a.latitude, a.longitude, b.latitude, b.longitude)
        if let cached = legs[key] { return completion(cached) }
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = .automobile
        MKDirections(request: request).calculate { response, _ in
            let leg = response?.routes.min { $0.distance < $1.distance }.map { Leg(meters: $0.distance, seconds: $0.expectedTravelTime) }
            if let leg { self.legs[key] = leg }
            completion(leg)
        }
    }
}
