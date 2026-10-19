import Foundation
import JavaScriptCore

/// The app's bridge to core/shift.js (shift totals, restaurant database, CSV export). One context, used on the main
/// actor only. Every argument is passed as JSON text.
@MainActor
enum ShiftEngine {
    private static let api: JSValue? = {
        guard let url = Bundle.main.url(forResource: "shift", withExtension: "js"),
              let code = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { return nil }
        context.evaluateScript(code)
        let api = context.objectForKeyedSubscript("Shift")
        return api?.isUndefined == false ? api : nil
    }()

    static func call(_ name: String, _ jsonArguments: [String]) -> String? {
        guard let function = api?.objectForKeyedSubscript(name), !function.isUndefined else { return nil }
        let result = function.call(withArguments: jsonArguments)
        guard let result, !result.isUndefined, !result.isNull else { return nil }
        return result.toString()
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    static func json<T: Encodable>(encodable value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static var offsetMinutes: Int { TimeZone.current.secondsFromGMT() / 60 }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}

/// Totals for one shift, computed by core/shift.js.
struct ShiftMetrics: Decodable, Equatable {
    struct App: Decodable, Equatable { let earningsCents: Int; let completed: Int }
    struct Miles: Decodable, Equatable {
        let toPickup, delivery, driveBack, reposition, order, deadhead, total: Double
        /// Of `total`, miles imported from Gridwise (week and day views only).
        let imported: Double?
    }
    struct Wait: Decodable, Equatable {
        let visits: Int
        let finished: Int
        let averageMinutes: Double?
        let longestMinutes: Double?
        let atLeastCount: Int
    }
    /// Time-of-day period (Breakfast, Lunch, Dinner, Late night, Early morning) a shift mostly fell in.
    struct Period: Decodable, Equatable { let key: String; let label: String }
    struct Goal: Decodable, Equatable {
        let goalCents: Int
        let progress: Double
        let remainingCents: Int
        let reached: Bool
        let etaAt: String?
    }
    let startedAt: String
    let endedAt: String?
    let live: Bool
    let earningsCents: Int
    let byPlatform: [String: App]
    let completed: Int
    let unassigned: Int
    let cancelled: Int
    let inProgress: Int
    let shiftSeconds: Int
    let activeSeconds: Int
    let idleSeconds: Int
    let miles: Miles
    let perOnlineHourCents: Int?
    let perActiveHourCents: Int?
    let perMileCents: Int?
    let restaurantWait: Wait
    let goal: Goal?
    let period: Period?
    /// One per delivered order, timed on the shift clock (user, Oct 15). Missing from totals saved before build 54.
    struct Completion: Decodable, Equatable {
        let offerId: String
        let platform: String
        let merchant: String?
        let payCents: Int
        let endedAt: String
        /// Shift time when it was delivered.
        let clockSeconds: Int
        /// Since the previous delivery (or the shift start), idle time included.
        let sinceLastSeconds: Int
        /// This order's pay for that shift time.
        let orderHourlyCents: Int?
        /// Shift earnings and hourly (earnings ÷ shift clock) right after it.
        let earningsCents: Int
        let hourlyCents: Int?
    }
    let completions: [Completion]?
    /// The shift hourly as of the last delivery; nil before the first one.
    let clockHourlyCents: Int?

    /// What the shift card shows: during a shift the hourly moves only when an order is delivered.
    var shiftHourlyCents: Int? { live ? clockHourlyCents : perOnlineHourCents }
}
