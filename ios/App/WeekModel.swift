import Foundation

/// Totals for any time range (a week or a day), from core/shift.js `rangeMetrics`. Days also list their orders,
/// shifts, and platforms, so every weekly number traces to the shifts and orders behind it.
struct RangeMetrics: Decodable, Equatable {
    struct App: Decodable, Equatable { let earningsCents: Int; let completed: Int }
    struct Wait: Decodable, Equatable {
        let visits: Int
        let finished: Int
        let atLeastCount: Int
        let averageMinutes: Double?
    }
    struct OrderRow: Decodable, Equatable, Identifiable {
        var id: String { offerId }
        let offerId: String
        let tripId: String
        let platform: String
        let stores: [String]
        let payCents: Int
        let acceptedAt: String
        let endedAt: String?
        let ended: String?
        let stacked: Bool
        let minutes: Double?
        let perHourCents: Int?
    }
    struct ShiftRef: Decodable, Equatable, Identifiable {
        let id: String
        let startedAt: String
        let endedAt: String?
        let period: ShiftMetrics.Period?
    }
    let from: String
    let to: String
    let earningsCents: Int
    let byPlatform: [String: App]
    let completed: Int
    let unassigned: Int
    let cancelled: Int
    let onlineSeconds: Int
    let activeSeconds: Int
    let idleSeconds: Int
    let miles: ShiftMetrics.Miles
    let perOnlineHourCents: Int?
    let perActiveHourCents: Int?
    let perMileCents: Int?
    let restaurantWait: Wait
    let orders: [OrderRow]?
    let shifts: [ShiftRef]?
    let platforms: [LensRow]?
}

/// One row of a lens (platform, area, restaurant, hour): earnings, orders, and the pace those orders earned.
struct LensRow: Decodable, Equatable, Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let earningsCents: Int
    let orders: Int
    let perHourCents: Int?
    let waitMinutes: Double?
}

struct WeekStats: Decodable, Equatable {
    struct Comparison: Decodable, Equatable {
        let earnings: Int?
        let perOnlineHour: Int?
        let perMile: Int?
        let deadhead: Int?
        let idle: Int?
        let storeWait: Int?
    }
    struct Lenses: Decodable, Equatable {
        let platform: [LensRow]
        let area: [LensRow]
        let restaurant: [LensRow]
        let period: [LensRow]
        let hour: [LensRow]
    }
    let week: RangeMetrics
    let days: [RangeMetrics]
    let previous: RangeMetrics?
    let comparison: Comparison?
    let lenses: Lenses
}

/// The selected week (Monday–Sunday, phone's calendar) and its stats. Never in the future.
@MainActor
final class WeekModel: ObservableObject {
    @Published private(set) var offset = 0   // 0 = this week, -1 = last week, …
    @Published private(set) var stats: WeekStats?
    @Published private(set) var days: [Date] = []
    var offers: [LiveOffer] = []

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        return calendar
    }

    var weekStart: Date {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .weekOfYear, value: offset, to: thisWeek) ?? thisWeek
    }
    var isCurrentWeek: Bool { offset == 0 }
    var canGoForward: Bool { offset < 0 }

    var rangeTitle: String {
        let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return weekStart.formatted(.dateTime.month(.abbreviated).day()) + " – " + end.formatted(.dateTime.month(.abbreviated).day())
    }
    var subtitle: String {
        switch offset {
        case 0: return "This week"
        case -1: return "Last week"
        default: return "\(-offset) weeks ago"
        }
    }
    /// Today's position (0 = Monday) when the current week is shown.
    var todayIndex: Int? {
        guard isCurrentWeek else { return nil }
        return days.firstIndex { calendar.isDateInToday($0) }
    }

    func move(_ delta: Int) {
        let next = min(0, offset + delta)
        guard next != offset else { return }
        offset = next
        stats = nil
        compute()
    }

    func jumpToThisWeek() { move(-offset) }

    /// Shows the week containing `date` (never a future week).
    func jump(to date: Date) {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let target = calendar.dateInterval(of: .weekOfYear, for: min(date, Date()))?.start ?? thisWeek
        let weeks = calendar.dateComponents([.weekOfYear], from: thisWeek, to: target).weekOfYear ?? 0
        move(min(0, weeks) - offset)
    }

    /// "Oct 12–18, 2026" (or "Sep 28 – Oct 4, 2026" across months), like Gridwise.
    var longTitle: String {
        let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let sameMonth = calendar.component(.month, from: weekStart) == calendar.component(.month, from: end)
        let first = weekStart.formatted(.dateTime.month(.abbreviated).day())
        let last = sameMonth ? end.formatted(.dateTime.day()) : end.formatted(.dateTime.month(.abbreviated).day())
        return first + (sameMonth ? "–" : " – ") + last + ", " + end.formatted(.dateTime.year())
    }

    func compute(now: Date = Date()) {
        let start = weekStart
        let dates = (0...7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        guard dates.count == 8, let previousStart = calendar.date(byAdding: .weekOfYear, value: -1, to: start) else { return }
        days = Array(dates.prefix(7))
        let iso = ISO8601DateFormatter()
        let from = previousStart.addingTimeInterval(-86_400), to = dates[7]
        let trips = (TripStore.shared.history + [TripStore.shared.active].compactMap { $0 })
            .filter { ($0.endedAt ?? now) >= from && $0.startedAt < to }
        let shifts = (ShiftStore.shared.history + [ShiftStore.shared.current].compactMap { $0 })
            .filter { ($0.endedAt ?? now) >= from && $0.startedAt < to }
        let offerRows: [[String: Any]] = offers.filter { $0.seenAt >= from && $0.seenAt < to }.map { offer in
            var row: [String: Any] = ["offerId": offer.offerId ?? offer.id]
            if let area = offer.dropoffArea { row["dropoffArea"] = area }
            return row
        }
        let dayRanges = (0..<7).map { ["start": iso.string(from: dates[$0]), "end": iso.string(from: dates[$0 + 1])] }
        let input = "{\"shifts\":\(ShiftEngine.json(encodable: shifts)),\"trips\":\(ShiftEngine.json(encodable: trips)),"
            + "\"offers\":\(ShiftEngine.json(offerRows)),\"restaurants\":\(RestaurantStore.shared.databaseJSON),"
            + "\"days\":\(ShiftEngine.json(dayRanges)),"
            + "\"previous\":\(ShiftEngine.json(["start": iso.string(from: previousStart), "end": iso.string(from: start)])),"
            + "\"now\":\(ShiftEngine.json(iso.string(from: now))),\"offsetMinutes\":\(ShiftEngine.offsetMinutes)}"
        let decoded = ShiftEngine.decode(WeekStats.self, ShiftEngine.call("weekStatsJSON", [input]))
        if decoded != stats { stats = decoded }
    }
}
