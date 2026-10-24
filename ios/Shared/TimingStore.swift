import Foundation

/// Learned trip-time corrections per app (core/shift.js `timeFactors`, user Oct 23: Grubhub shows no time until you
/// accept). The app works them out from your finished orders and writes them here; the offer reader multiplies its own
/// trip-time estimates by them. Without an App Group the reader keeps its plain estimates.
enum TimingStore {
    private static let fileName = "timing.json"
    private static let localKey = "timeFactors"

    private static func sharedURL() -> URL? { try? AppGroup.container().appendingPathComponent(fileName) }

    /// e.g. ["grubhub": 1.25]; empty until 3 orders from an app had an estimated time.
    static var factors: [String: Double] {
        if let url = sharedURL(), let data = try? Data(contentsOf: url),
           let value = try? JSONDecoder().decode([String: Double].self, from: data) { return value }
        if let data = UserDefaults.standard.data(forKey: localKey), let value = try? JSONDecoder().decode([String: Double].self, from: data) { return value }
        return [:]
    }

    static func save(_ factors: [String: Double]) {
        guard factors != Self.factors, let data = try? JSONEncoder().encode(factors) else { return }
        UserDefaults.standard.set(data, forKey: localKey)
        if let url = sharedURL() { try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }

    /// The rules plus the learned factors, as the reader's settings JSON.
    static func settingsJSON(_ rules: Rules) -> String {
        let factors = Self.factors.filter { $0.value >= 0.5 && $0.value <= 3 }
        guard !factors.isEmpty, let data = try? JSONEncoder().encode(factors), let text = String(data: data, encoding: .utf8) else {
            return rules.settingsJSON
        }
        return String(rules.settingsJSON.dropLast()) + ",\"timeFactors\":" + text + "}"
    }
}
