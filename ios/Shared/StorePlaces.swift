import Foundation
import CoreLocation

/// Where the restaurants you've arrived at really are (user, Oct 23: reader upgrade 3). The app writes the positions it
/// learned from your arrivals; the offer reader uses one to pin the store on an offer's map exactly, instead of an Apple
/// Maps search or town names. Businesses only — never customers. Needs the App Group; without it the reader searches as
/// before.
struct StorePlace: Codable, Equatable {
    /// The store's names, normalized ("lou malnatis", "chipotle").
    let keys: [String]
    let lat: Double
    let lon: Double
}

enum StorePlaces {
    private static let fileName = "store-places.json"

    private static func sharedURL() -> URL? { try? AppGroup.container().appendingPathComponent(fileName) }

    static func save(_ places: [StorePlace]) {
        guard let data = try? JSONEncoder().encode(places) else { return }
        Bridge.publish("store-places", data)
        guard let url = sharedURL() else { return }
        if let old = try? Data(contentsOf: url), old == data { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func load() -> [StorePlace] {
        let data = sharedURL().flatMap { try? Data(contentsOf: $0) } ?? Bridge.read("store-places")
        return data.flatMap { try? JSONDecoder().decode([StorePlace].self, from: $0) } ?? []
    }

    /// Like core/shift.js `normalizeName`: "Lou Malnati's (Franklin)" → "lou malnatis", "Crisp & Green" → "crisp and green".
    static func normalize(_ name: String) -> String {
        var s = name.lowercased()
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"['’`]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("the ") { s.removeFirst(4) }
        s = s.replacingOccurrences(of: #" (restaurant|restaurants|kitchen|grill)$"#, with: "", options: .regularExpression)
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// The known store with this name nearest `near` (a chain has several), within 25 miles; nil if none is known.
    static func nearest(_ name: String, near: CLLocation?, in places: [StorePlace] = load()) -> (Double, Double)? {
        let key = normalize(name)
        guard !key.isEmpty else { return nil }
        let named = places.filter { $0.keys.contains(key) }
        guard let near else { return named.count == 1 ? (named[0].lat, named[0].lon) : nil }
        let best = named.map { ($0, near.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon))) }
            .filter { $0.1 <= 40_000 }.min { $0.1 < $1.1 }
        return best.map { ($0.0.lat, $0.0.lon) }
    }
}
