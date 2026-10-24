import Foundation

/// The driver's rules (user: $1 per mile incl. the return, $25/hour), editable in Account. Like the return destination,
/// the app writes them to the App Group and the offer reader reads them for every offer; without an App Group the reader
/// keeps the defaults (the app says so).
struct Rules: Codable, Equatable {
    var centsPerMile: Int
    var hourlyTargetCents: Int

    static let defaults = Rules(centsPerMile: 100, hourlyTargetCents: 2500)

    /// Settings for core/copilot.js and core/screen-reader.js.
    var settingsJSON: String { "{\"centsPerMile\":\(centsPerMile),\"hourlyTargetCents\":\(hourlyTargetCents)}" }
    var perMileText: String { String(format: "$%.2f", Double(centsPerMile) / 100).replacingOccurrences(of: ".00", with: "") }
    var hourlyText: String { "$\(hourlyTargetCents / 100)/hr" }
}

enum RulesStore {
    private static let fileName = "rules.json"
    private static let localKey = "rules"

    private static func sharedURL() -> URL? { try? AppGroup.container().appendingPathComponent(fileName) }

    static var current: Rules {
        let decoder = JSONDecoder()
        if let url = sharedURL(), let data = try? Data(contentsOf: url), let rules = try? decoder.decode(Rules.self, from: data) { return rules }
        if let data = UserDefaults.standard.data(forKey: localKey), let rules = try? decoder.decode(Rules.self, from: data) { return rules }
        if let data = Bridge.read("rules"), let rules = try? decoder.decode(Rules.self, from: data) { return rules }
        return .defaults
    }

    static var isShared: Bool { sharedURL() != nil }

    /// Saves the rules; returns whether the offer reader can see them.
    @discardableResult
    static func save(_ rules: Rules) -> Bool {
        let clean = Rules(centsPerMile: min(500, max(25, rules.centsPerMile)), hourlyTargetCents: min(10_000, max(500, rules.hourlyTargetCents)))
        guard let data = try? JSONEncoder().encode(clean) else { return false }
        UserDefaults.standard.set(data, forKey: localKey)
        Bridge.publish("rules", data)
        guard let url = sharedURL() else { return false }
        return (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }
}
