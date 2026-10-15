import Foundation

struct Restaurant: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let aliases: [String]
    let platforms: [String]
    let lat: Double?
    let lon: Double?
    let offers: Int
    let visits: Int
    let lastSeen: String?
}

struct RestaurantStat: Decodable, Equatable {
    struct Period: Decodable, Equatable { let waits: Int; let averageMinutes: Double }
    let visits: Int
    let waits: Int
    let averageMinutes: Double?
    let longestSeconds: Int
    let atLeast: [Int]
    let byPeriod: [String: Period]
}

struct MergeSuggestion: Decodable, Identifiable {
    let id: String
    let name: String
    let score: Double
    let miles: Double?
}

/// Restaurants built automatically from offer cards (store names) and the stores the driver ticked as arrived (with
/// the phone's position there — a business location). Different apps' names for one store can be merged by the
/// driver; later offers under any merged name count toward it. Logic in core/shift.js; stored in the app container.
@MainActor
final class RestaurantStore: ObservableObject {
    static let shared = RestaurantStore()

    @Published private(set) var restaurants: [Restaurant] = []
    @Published private(set) var stats: [String: RestaurantStat] = [:]
    private var db = "null"
    private var signature = ""

    private init() {
        if let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8) { db = text }
        decode()
    }

    /// Adds new offers and store visits (cheap when nothing changed).
    func update(offers: [LiveOffer], trips: [Trip]) {
        let steps = trips.reduce(0) { $0 + $1.steps.count }
        let newSignature = "\(offers.count)|\(offers.last?.id ?? "")|\(trips.count)|\(steps)"
        guard newSignature != signature else { return }
        signature = newSignature
        let offerRows: [[String: Any]] = offers.map { offer in
            var row: [String: Any] = ["id": offer.offerId ?? offer.id, "platform": offer.platform,
                                      "seenAt": ISO8601DateFormatter().string(from: offer.seenAt)]
            if let merchants = offer.merchants { row["merchants"] = merchants }
            if let merchant = offer.merchant { row["merchant"] = merchant }
            return row
        }
        let input = "{\"offers\":\(ShiftEngine.json(offerRows)),\"trips\":\(ShiftEngine.json(encodable: trips))}"
        if let updated = ShiftEngine.call("updateRestaurantsJSON", [db, input]) { db = updated; save() }
        decode(trips: trips)
    }

    func merge(_ sourceId: String, into targetId: String) {
        if let updated = ShiftEngine.call("mergeRestaurantsJSON", [db, ShiftEngine.json(sourceId), ShiftEngine.json(targetId)]) {
            db = updated; save(); decode(trips: allTrips)
        }
    }

    func rename(_ id: String, to name: String) {
        if let updated = ShiftEngine.call("renameRestaurantJSON", [db, ShiftEngine.json(id), ShiftEngine.json(name)]) {
            db = updated; save(); decode(trips: allTrips)
        }
    }

    func suggestions(for id: String) -> [MergeSuggestion] {
        ShiftEngine.decode([MergeSuggestion].self, ShiftEngine.call("mergeSuggestionsJSON", [db, ShiftEngine.json(id)])) ?? []
    }

    /// The raw database, for export.
    var databaseJSON: String { db }

    /// Starts the list over from the given offers and trips (after demo data is removed). Merges are not kept.
    func rebuild(offers: [LiveOffer], trips: [Trip]) {
        db = "null"
        signature = ""
        update(offers: offers, trips: trips)
        save()
    }

    /// Restores a backed-up database (merges and names come back with it) unless this install already has a bigger list;
    /// offers and visits seen since are added back on the next update.
    @discardableResult
    func restore(_ json: String) -> Bool {
        guard json != "null", !json.isEmpty, let backup = ShiftEngine.decode(Database.self, json),
              backup.restaurants.count >= restaurants.count else { return false }
        db = json
        signature = ""
        save()
        decode(trips: allTrips)
        return true
    }

    private var allTrips: [Trip] { TripStore.shared.history + [TripStore.shared.active].compactMap { $0 } }

    private struct Database: Decodable { let restaurants: [Restaurant] }

    private func decode(trips: [Trip]? = nil) {
        let list = ShiftEngine.decode(Database.self, db)?.restaurants ?? []
        if list != restaurants { restaurants = list }
        let tripsJSON = ShiftEngine.json(encodable: trips ?? allTrips)
        let computed = ShiftEngine.decode([String: RestaurantStat].self,
                                          ShiftEngine.call("restaurantStatsJSON", [db, tripsJSON, ShiftEngine.json(ShiftEngine.offsetMinutes)])) ?? [:]
        if computed != stats { stats = computed }
    }

    private var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("restaurants.json")
    }

    private func save() {
        guard !PreviewData.isActive, let url = fileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? db.write(to: url, atomically: true, encoding: .utf8)
    }
}
