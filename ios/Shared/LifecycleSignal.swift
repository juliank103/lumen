import Foundation

/// An order state seen on screen (core/screen-reader.js `readStatus`), sent from the offer reader to the app as a Darwin
/// notification named after the app and state — no data, no App Group needed. The app, running for the shift, turns it
/// into trip steps. Only states that move a trip are sent.
///
/// Pickup screens also carry a short code for the store they show (`store`, one of 32, from its first distinctive word),
/// so the app accepts only an offer from that store (user, Oct 18 shift: Uber's pickup screen for an order __APP_NAME__ hadn't
/// read was taken as an accept of the offer just declined — Pizzeria Deville while heading to Chipotle).
struct LifecycleSignal: Hashable {
    static let platforms = ["doordash", "uber_eats", "grubhub"]
    static let states = ["available", "heading_to_store", "at_store", "heading_to_customer", "at_customer", "delivered"]
    static let storeStates = ["heading_to_store", "at_store"]
    static let buckets = 32

    let platform: String
    let state: String
    /// The store's code (0..<32) on a pickup screen that names its store; nil otherwise.
    let store: Int?

    var name: String {
        "com.juliank103.mellodycopilot.lifecycle.\(platform).\(state)" + (store.map { ".s\($0)" } ?? "")
    }

    static let all: [LifecycleSignal] = platforms.flatMap { platform in
        states.map { LifecycleSignal(platform: platform, state: $0) }
            + storeStates.flatMap { state in (0..<buckets).map { LifecycleSignal(platform: platform, state: state, store: $0) } }
    }

    init(platform: String, state: String, store: Int? = nil) {
        self.platform = platform
        self.state = state
        self.store = store
    }

    init?(name: String) {
        guard let match = Self.all.first(where: { $0.name == name }) else { return nil }
        self = match
    }

    func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    // MARK: Store codes

    /// Words that say nothing about which store it is.
    private static let generic: Set<String> = ["the", "and", "large", "boxes", "mpx", "restaurant", "restaurants", "bar", "grill",
                                               "kitchen", "cafe", "store", "pickup", "pick", "order", "orders", "take", "out"]

    /// Distinctive words of a store name, in order: "Chipotle Mexican Grill (375 N Milwauke" → chipotle, mexican, milwauke.
    static func words(_ storeName: String) -> [String] {
        storeName.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "['’`]", with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 3 && !generic.contains($0) }
    }

    private static func code(_ word: String) -> Int {
        var h: UInt32 = 0x811c9dc5
        for byte in word.utf8 { h ^= UInt32(byte); h = h &* 0x01000193 }
        return Int(h % UInt32(buckets))
    }

    /// The code a pickup screen sends: its store name's first distinctive word.
    static func storeCode(_ storeName: String?) -> Int? {
        storeName.flatMap { words($0).first }.map(code)
    }

    /// Every code an offer's store names could show as (any distinctive word), for matching a pickup screen.
    static func storeCodes(_ storeNames: [String]) -> Set<Int> {
        Set(storeNames.flatMap(words).map(code))
    }
}
