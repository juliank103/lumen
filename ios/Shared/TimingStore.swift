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
        /// Restaurants slow at lunch or dinner (user, Oct 28; core/shift.js `storeWaits`): meal → store key → extra minutes.
        var storeWaits: [String: [String: Int]]? = nil
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
    static func settingsJSON(_ standard: Rules) -> String {
        let timing = current
        var extra = "", rules = standard
        // The weekday bar (Oct 27): today's bar in place of the rules, the rules themselves as "standard".
        if let bar = SlowHours.dayBar(standard) {
            rules.hourlyTargetCents = bar.hourlyCents; rules.centsPerMile = bar.centsPerMile
            extra += ",\"standard\":{\"hourlyCents\":\(standard.hourlyTargetCents),\"centsPerMile\":\(standard.centsPerMile)}"
        }
        let factors = timing.factors.filter { $0.value >= 0.5 && $0.value <= 3 }
        if !factors.isEmpty, let data = try? JSONEncoder().encode(factors), let text = String(data: data, encoding: .utf8) {
            extra += ",\"timeFactors\":" + text
        }
        if timing.returnShare >= 0.3 && timing.returnShare < 1 { extra += String(format: ",\"returnTimeShare\":%.2f", timing.returnShare) }
        // A lower bar when good offers are rare (Oct 26).
        if let bar = SlowHours.barJSON() { extra += ",\"slowBar\":" + bar }
        // The last order, judged on what it adds to the drive home (Oct 28).
        if ReturnDestinationStore.headingHome { extra += ",\"headingHome\":true" }
        // Restaurants slow at this meal time (Oct 28): lunch 10–15, dinner 15–22, as core/shift.js storeWaits.
        let hour = Calendar.current.component(.hour, from: Date())
        let meal = hour >= 10 && hour < 15 ? "lunch" : hour >= 15 && hour < 22 ? "dinner" : nil
        if let meal, let waits = timing.storeWaits?[meal], !waits.isEmpty,
           let data = try? JSONEncoder().encode(waits), let text = String(data: data, encoding: .utf8) {
            extra += ",\"storeWaits\":" + text
        }
        return extra.isEmpty ? rules.settingsJSON : String(rules.settingsJSON.dropLast()) + extra + "}"
    }
}
