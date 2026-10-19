import Foundation
import MapKit

/// Where a restaurant is, for one __APP_NAME__ has no arrivals at yet: an Apple Maps search of its name (with the address in
/// Uber's "(123 Main St Ste 100)" when a name has one), closest to the area. For the Zones heat map and the
/// restaurant page's map (user, Oct 19: "let me view the location of a restaurant… i can't figure out which ones to
/// merge"). Kept apart from the arrival positions, which stay the trusted ones: a search can find the wrong branch.
struct RestaurantPlace: Codable, Equatable {
    let lat: Double?
    let lon: Double?
    /// Apple Maps' name and address for the match ("Chipotle Mexican Grill", "123 Main St, Springfield").
    let title: String?
    let address: String?
    let searchedAt: Date

    var coordinate: CLLocationCoordinate2D? { lat.flatMap { lat in lon.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } } }
}

@MainActor
final class RestaurantPlaces: ObservableObject {
    static let shared = RestaurantPlaces()

    /// By restaurant id. A miss (no coordinate) is kept too, and searched again after a week.
    @Published private(set) var places: [String: RestaurantPlace] = [:]
    @Published private(set) var searching = false
    private var queue: [String] = []

    private init() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        places = (try? decoder.decode([String: RestaurantPlace].self, from: data)) ?? [:]
    }

    /// Where a restaurant is and how __APP_NAME__ knows: your arrivals first, else the Apple Maps match.
    func location(of r: Restaurant) -> (coordinate: CLLocationCoordinate2D, fromArrivals: Bool)? {
        if let lat = r.lat, let lon = r.lon { return (coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), fromArrivals: true) }
        return places[r.id]?.coordinate.map { (coordinate: $0, fromArrivals: false) }
    }

    /// Searched positions for the heat map: {id: {lat, lon}}.
    var json: String {
        var out: [String: [String: Double]] = [:]
        for (id, place) in places { if let lat = place.lat, let lon = place.lon { out[id] = ["lat": lat, "lon": lon] } }
        return ShiftEngine.json(out)
    }

    /// Looks up restaurants not searched yet (or missed over a week ago), most-offered first, a few at a time (Apple Maps
    /// allows about 50 searches a minute).
    func find(_ ids: [String], limit: Int = 25) {
        let due = ids.filter { id in
            guard !queue.contains(id) else { return false }
            guard let known = places[id] else { return true }
            return known.lat == nil && Date().timeIntervalSince(known.searchedAt) > 7 * 86_400
        }
        queue.append(contentsOf: due.prefix(limit))
        guard !searching, !queue.isEmpty else { return }
        searching = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard let r = RestaurantStore.shared.restaurants.first(where: { $0.id == id }) else { continue }
            places[id] = await search(r)
            save()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        searching = false
    }

    private func search(_ r: Restaurant) async -> RestaurantPlace {
        let center = LocationAccess.manager.location?.coordinate ?? CLLocationCoordinate2D(latitude: __AREA_LAT__, longitude: __AREA_LON__)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = Self.query(for: r)
        request.region = MKCoordinateRegion(center: center, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        request.resultTypes = .pointOfInterest
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let first = Self.firstWord(r.name)
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        // The closest result whose name shares the restaurant's first word (not a nearby store of another brand).
        let best = items.filter { item in
            guard let location = item.placemark.location, location.distance(from: here) < 40_000 else { return false }
            return first.isEmpty || Self.firstWord(item.name ?? "") == first
        }.min { ($0.placemark.location?.distance(from: here) ?? .infinity) < ($1.placemark.location?.distance(from: here) ?? .infinity) }
        guard let best else { return RestaurantPlace(lat: nil, lon: nil, title: nil, address: nil, searchedAt: Date()) }
        let p = best.placemark
        let address = [p.subThoroughfare.map { $0 + " " + (p.thoroughfare ?? "") } ?? p.thoroughfare, p.locality]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        return RestaurantPlace(lat: p.coordinate.latitude, lon: p.coordinate.longitude, title: best.name,
                               address: address.isEmpty ? nil : address, searchedAt: Date())
    }

    /// The name with an address in brackets when any of its names has one ("Chipotle Mexican Grill 123 Main St
    /// Ste 100"), or with a place ("Shake Shack Springfield"); else the plain name.
    static func query(for r: Restaurant) -> String {
        let bracket = #"\(([^)]*)\)"#
        let names = [r.name] + r.aliases
        func inside(_ name: String) -> String? {
            guard let range = name.range(of: bracket, options: .regularExpression) else { return nil }
            return String(name[range]).trimmingCharacters(in: CharacterSet(charactersIn: "()")).trimmingCharacters(in: .whitespaces)
        }
        func plain(_ name: String) -> String {
            name.replacingOccurrences(of: bracket, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        if let withNumber = names.first(where: { inside($0)?.range(of: #"^\d"#, options: .regularExpression) != nil }) {
            return plain(withNumber) + " " + (inside(withNumber) ?? "")
        }
        if let withPlace = names.first(where: { inside($0) != nil }) { return plain(withPlace) + " " + (inside(withPlace) ?? "") }
        return plain(r.name)
    }

    static func firstWord(_ name: String) -> String {
        AutoSteps.normalize(name).split(separator: " ").first { !["the"].contains($0) }.map(String.init) ?? ""
    }

    private var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("restaurant-places.json")
    }

    private func save() {
        guard !PreviewData.isActive, let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(places).write(to: url, options: .atomic)
    }
}
