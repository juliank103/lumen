import Foundation

/// What __APP_NAME__ learned about time from your own orders, for the offer reader:
/// - per-app trip-time corrections (core/shift.js `timeFactors`, user Oct 23: Grubhub shows no time until you accept);
/// - the share of the drive back you really lose before the next order (`returnShare`, user Oct 24: "I bank on getting
///   orders during the return"), which is how much of the drive back counts toward $/hr.
/// The app works them out and writes them here; the reader reads them with the rules. Without an App Group the reader
/// keeps its plain estimates and counts the whole drive back.
enum TimingStore {
    struct Timing: Codable, Equatable {
        var factors: [String: Double] = [:]
        var returnShare: Double = 1
        /// Orders the share was learned from.
        var returnShareOrders: Int = 0
    }

    private static let fileName = "timing.json"
    private static let localKey = "timing"

    private static func sharedURL() -> URL? { try? AppGroup.container().appendingPathComponent(fileName) }

    static var current: Timing {
        let decoder = JSONDecoder()
        if let url = sharedURL(), let data = try? Data(contentsOf: url) {
            if let value = try? decoder.decode(Timing.self, from: data) { return value }
            // Build 65 stored the factors alone.
            if let factors = try? decoder.decode([String: Double].self, from: data) { return Timing(factors: factors) }
        }
        if let data = UserDefaults.standard.data(forKey: localKey), let value = try? decoder.decode(Timing.self, from: data) { return value }
        // The reader without an App Group: what the app handed over through the bridge.
        if let data = Bridge.read("timing"), let value = try? decoder.decode(Timing.self, from: data) { return value }
        return Timing()
    }

    static var factors: [String: Double] { current.factors }

    static func save(_ timing: Timing) {
        guard let data = try? JSONEncoder().encode(timing) else { return }
        Bridge.publish("timing", data)
        guard timing != current else { return }
        UserDefaults.standard.set(data, forKey: localKey)
        if let url = sharedURL() { try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }

    /// The rules plus what was learned, as the reader's settings JSON.
    static func settingsJSON(_ rules: Rules) -> String {
        let timing = current
        var extra = ""
        let factors = timing.factors.filter { $0.value >= 0.5 && $0.value <= 3 }
        if !factors.isEmpty, let data = try? JSONEncoder().encode(factors), let text = String(data: data, encoding: .utf8) {
            extra += ",\"timeFactors\":" + text
        }
        if timing.returnShare >= 0.3 && timing.returnShare < 1 { extra += String(format: ",\"returnTimeShare\":%.2f", timing.returnShare) }
        return extra.isEmpty ? rules.settingsJSON : String(rules.settingsJSON.dropLast()) + extra + "}"
    }
}
