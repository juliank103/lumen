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
    /// The one reason behind the verdict ("On the way back · saves 4.1 mi", "Too slow · 17 min for $5.10"): the
    /// notification's second line and the Home card (user, Oct 22). Nil on older offers.
    let why: String?
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
    /// Reading data (user, Oct 21): the card's text lines as "y|x|w|h|text" (no map, no cross streets), and what the
    /// map reader saw on screen (pins, icons, dot, town labels; no coordinates). Kept 30 days; off in Account.
    let cardLines: [String]?
    let mapSnapshot: String?
    /// Reader 2 trial (Oct 24): what Apple's structured document reader found on the card, as JSON
    /// {payCents: [...], milliMiles: [...], minutes: [...], ms}, to compare with the reader's fields.
    let docRead: String?
    let headline: String
    let detail: String
    let fingerprint: String
}

extension LiveOffer {
    /// Whether to keep the reading data (card text, map snapshot) with offers. On unless turned off in Account.
    static var keepsReadingData: Bool { UserDefaults.standard.object(forKey: "keepReadingData") as? Bool ?? true }

    /// The same offer without its reading data (turned off, or older than 30 days).
    func withoutReadingData() -> LiveOffer {
        guard cardLines != nil || mapSnapshot != nil else { return self }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return self }
        object["cardLines"] = nil
        object["mapSnapshot"] = nil
        guard let stripped = try? JSONSerialization.data(withJSONObject: object),
              let offer = try? decoder.decode(LiveOffer.self, from: stripped) else { return self }
        return offer
    }
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
