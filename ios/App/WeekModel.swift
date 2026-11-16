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
    /// Added by hand (＋): tips/bonuses/other earnings (already in earningsCents), expenses, and net.
    struct EntryRow: Decodable, Equatable, Identifiable {
        let id: String
        let kind: String
        let at: String
        let amountCents: Int
        let category: String?
        let platform: String?
        let note: String?
    }
    let extrasCents: Int?
    /// Gridwise's hours, miles, and deduction for imported days (already in online time, miles, and the deduction).
    let importedSeconds: Int?
    let importedMiles: Double?
    let importedDeductionCents: Int?
    let expensesCents: Int?
    let netCents: Int?
    let entries: [EntryRow]?
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

/// Week, month or year on the Earnings page (user, Nov 15: "a monthly and yearly earnings screen that has the same stats
/// as the regular earnings screen").
enum EarningsSpan: String, CaseIterable, Identifiable {
    case week = "Week", month = "Month", year = "Year"
    var id: String { rawValue }
    var component: Calendar.Component { self == .week ? .weekOfYear : self == .month ? .month : .year }
    /// Each bar of the chart: a day, or a month for a year.
    var bucket: Calendar.Component { self == .year ? .month : .day }
    var noun: String { rawValue.lowercased() }
}

/// The selected week (Monday–Sunday, phone's calendar), month or year and its stats, from the same engine
/// (core/shift.js `weekStats`, whose "days" are the chart's buckets: days, or months for a year). Never in the future.
@MainActor
final class WeekModel: ObservableObject {
    @Published private(set) var span = EarningsSpan.week
    @Published private(set) var offset = 0   // 0 = this week/month/year, -1 = the one before, …
    @Published private(set) var stats: WeekStats?
    /// The start of each bucket (day, or month for a year).
    @Published private(set) var days: [Date] = []
    var offers: [LiveOffer] = []

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        return calendar
    }

    var weekStart: Date {
        let now = calendar.dateInterval(of: span.component, for: Date())?.start ?? calendar.startOfDay(for: Date())
        return calendar.date(byAdding: span.component, value: offset, to: now) ?? now
    }
    private var periodEnd: Date { calendar.date(byAdding: span.component, value: 1, to: weekStart) ?? weekStart }
    var isCurrentWeek: Bool { offset == 0 }
    var canGoForward: Bool { offset < 0 }

    var subtitle: String {
        switch offset {
        case 0: return "This " + span.noun
        case -1: return "Last " + span.noun
        default: return "\(-offset) \(span.noun)s ago"
        }
    }
    /// Today's bar when the current period is shown.
    var todayIndex: Int? {
        guard isCurrentWeek else { return nil }
        return days.firstIndex { calendar.isDate($0, equalTo: Date(), toGranularity: span.bucket) }
    }

    func move(_ delta: Int) {
        let next = min(0, offset + delta)
        guard next != offset else { return }
        offset = next
        stats = nil
        compute()
    }

    func jumpToThisWeek() { move(-offset) }

    /// Shows the period containing `date` (never a future one).
    func jump(to date: Date) {
        let now = calendar.dateInterval(of: span.component, for: Date())?.start ?? Date()
        let target = calendar.dateInterval(of: span.component, for: min(date, Date()))?.start ?? now
        let steps = calendar.dateComponents([span.component], from: now, to: target).value(for: span.component) ?? 0
        move(min(0, steps) - offset)
    }

    /// Week, month or year, keeping the date shown: the week of the month shown becomes its month, and so on (the
    /// current period when it's the current one).
    func show(_ next: EarningsSpan, at date: Date? = nil) {
        let anchor = date ?? (isCurrentWeek ? Date() : weekStart)
        guard next != span || date != nil else { return }
        span = next
        offset = 0
        stats = nil
        jump(to: anchor)
        if offset == 0 { compute() }
    }

    /// "Oct 12–18, 2026" (or "Sep 28 – Oct 4, 2026" across months), like Gridwise; "November 2026"; "2026".
    var longTitle: String {
        switch span {
        case .month: return weekStart.formatted(.dateTime.month(.wide).year())
        case .year: return weekStart.formatted(.dateTime.year())
        case .week:
            let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
            let sameMonth = calendar.component(.month, from: weekStart) == calendar.component(.month, from: end)
            let first = weekStart.formatted(.dateTime.month(.abbreviated).day())
            let last = sameMonth ? end.formatted(.dateTime.day()) : end.formatted(.dateTime.month(.abbreviated).day())
            return first + (sameMonth ? "–" : " – ") + last + ", " + end.formatted(.dateTime.year())
        }
    }

    func compute(now: Date = Date()) {
        let start = weekStart, end = periodEnd
        var dates: [Date] = []
        var d = start
        while d < end, dates.count < 40 {
            dates.append(d)
            guard let next = calendar.date(byAdding: span.bucket, value: 1, to: d) else { break }
            d = next
        }
        guard !dates.isEmpty, let previousStart = calendar.date(byAdding: span.component, value: -1, to: start) else { return }
        days = dates
        let bounds = dates + [end]
        let iso = ISO8601DateFormatter()
        let from = previousStart.addingTimeInterval(-86_400), to = end
        let trips = (TripStore.shared.history + [TripStore.shared.active].compactMap { $0 })
            .filter { ($0.endedAt ?? now) >= from && $0.startedAt < to }
        let shifts = (ShiftStore.shared.history + [ShiftStore.shared.current].compactMap { $0 })
            .filter { ($0.endedAt ?? now) >= from && $0.startedAt < to }
        let offerRows: [[String: Any]] = offers.filter { $0.seenAt >= from && $0.seenAt < to }.map { offer in
            var row: [String: Any] = ["offerId": offer.offerId ?? offer.id]
            if let area = offer.dropoffArea { row["dropoffArea"] = area }
            return row
        }
        let dayRanges = dates.indices.map { ["start": iso.string(from: bounds[$0]), "end": iso.string(from: bounds[$0 + 1])] }
        let input = "{\"shifts\":\(ShiftEngine.json(encodable: shifts)),\"trips\":\(ShiftEngine.json(encodable: trips)),"
            + "\"offers\":\(ShiftEngine.json(offerRows)),\"restaurants\":\(RestaurantStore.shared.databaseJSON),"
            + "\"days\":\(ShiftEngine.json(dayRanges)),\"entries\":\(EntryStore.shared.json),"
            + "\"previous\":\(ShiftEngine.json(["start": iso.string(from: previousStart), "end": iso.string(from: start)])),"
            + "\"now\":\(ShiftEngine.json(iso.string(from: now))),\"offsetMinutes\":\(ShiftEngine.offsetMinutes)}"
        let decoded = ShiftEngine.decode(WeekStats.self, ShiftEngine.call("weekStatsJSON", [input]))
        if decoded != stats { stats = decoded }
    }
}
