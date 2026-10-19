import Foundation

// Offer fields and verdict only, produced by core/screen-reader.js. No screen text, images, or customer details.
struct LiveOffer: Codable, Identifiable {
    var id: String { "\(seenAt.timeIntervalSince1970)|\(fingerprint)" }
    let seenAt: Date
    let platform: String
    let payCents: Int
    let outboundMilliMiles: Int?
    let appMinutes: Int?
    let merchant: String?
    let dropoffArea: String?
    let orderCount: Int?
    /// Stores and drop-offs on the card, for the trip steps (multi-pickup / multi-drop-off offers).
    let merchants: [String]?
    let pickupCount: Int?
    let dropoffCount: Int?
    let confidence: Double
    let tone: String
    let maxReturnMilliMiles: Int?
    /// Apple Maps return to __HOME_NAME__: "dropoff", "dropoff_town", or "worst_case" (an upper bound). Nil if not routed.
    let returnMilliMiles: Int?
    let returnKind: String?
    /// Notification line: "$1.30/mi · Accept", "$0.74/mi · Decline", or "Accept if return ≤ 4.4 mi".
    let notice: String?
    /// Why no return was calculated, for the offer list.
    let returnNote: String?
    /// Which return step ran and what the map reader found (counts, town names, destination). No customer details.
    let returnDebug: String?
    /// How the trip time was estimated when the card showed none.
    let tripTimeNote: String?
    /// Predicted by the refined verdict (for "predicted vs actual" after the order): effective miles, $/hr, trip and
    /// return minutes. Nil on offers from before build 41 or when not worked out.
    let effectiveMilliMiles: Int?
    let hourlyCents: Int?
    let tripMinutes: Int?
    let returnMinutes: Int?
    /// Stable ID shared with the journal (roadmap §7).
    let offerId: String?
    /// Stage-1 notification line, and whether a refined UPDATE was sent.
    let preliminaryNotice: String?
    let updated: Bool?
    /// Milliseconds from the card first being seen to the first notification, and to the refined result.
    let latencyFirstMs: Int?
    let latencyRefinedMs: Int?
    /// Where the phone was when the offer came (rounded to ~100 m; the driver's own position, never the customer's), for
    /// the Zones heat map. Nil on older offers or when the reader had no position.
    let waitLat: Double?
    let waitLon: Double?
    let headline: String
    let detail: String
    let fingerprint: String
}

enum LiveOfferStorage {
    static let limit = 100

    static func url() throws -> URL {
        try AppGroup.container().appendingPathComponent("live-offers.json")
    }

    // Offers ride inside their notification so the app can list them even without a shared App Group.
    static let notificationKey = "offer"

    static func notificationValue(_ offer: LiveOffer) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(offer)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func fromNotification(_ userInfo: [AnyHashable: Any]) -> LiveOffer? {
        guard let text = userInfo[notificationKey] as? String, let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LiveOffer.self, from: data)
    }

    static func read() throws -> [LiveOffer] {
        let location = try url()
        guard FileManager.default.fileExists(atPath: location.path) else { return [] }
        let data = try Data(contentsOf: location)
        guard data.count < 512_000 else { throw CocoaError(.fileReadCorruptFile) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LiveOffer].self, from: data)
    }

    static func append(_ offer: LiveOffer) throws {
        var offers = (try? read()) ?? []
        offers.append(offer)
        if offers.count > limit { offers.removeFirst(offers.count - limit) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(offers).write(to: try url(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
