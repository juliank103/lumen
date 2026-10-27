import Foundation

/// Slow hours (user, Oct 26: "Perhaps there are some shifts or consistent times where I need to lower my expectations").
/// The rules ($1/mi, $25/hr) stay the standard; when good offers are rare, an offer that misses them but clears a lower
/// bar gets a labeled "Accept (slow hour)". The user's bands: $23.50–25 good, $21–23.49 a step down, $20–21 bottom of
/// the barrel; $/mi steps down alongside ($0.95, $0.90, $0.85).
/// How far down: the weekday and meal time's tier, learned by the app from how often an offer met the rules there
/// (core/shift.js `slowSlots`), plus a live step in the reader — no offer meeting the rules for 30 minutes of reading
/// tonight is one step more, 60 minutes two.
enum SlowHours {
    static let storeKey = "slowSlots"
    private static let bars: [(hourlyCents: Int, centsPerMile: Int)] = [(2350, 95), (2100, 90), (2000, 85)]

    /// Tier per "weekday|meal" (weekday 0 = Sunday): 0 normal … 3 dead.
    static func slots() -> [String: Int] { UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Int] ?? [:] }

    static func slotKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.weekday, .hour], from: date)
        let hour = c.hour ?? 0
        return "\((c.weekday ?? 1) - 1)|" + (hour >= 10 && hour < 15 ? "lunch" : hour >= 15 && hour < 22 ? "dinner" : "other")
    }

    private static let lock = NSLock()
    private static var minutesWithoutGood = 0
    private static var standardOffers: [(id: String, at: Date)] = []

    /// The reader: minutes of reading since the last offer that met the rules.
    static func noteLive(minutesWithoutGood minutes: Int) {
        lock.lock(); minutesWithoutGood = max(0, minutes); lock.unlock()
    }

    /// The reader: an offer that met the full rules (counted once per offer).
    static func noteStandardOffer(id: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        standardOffers.removeAll { date.timeIntervalSince($0.at) > 1800 }
        if !standardOffers.contains(where: { $0.id == id }) { standardOffers.append((id, date)) }
    }

    /// Busy (user, Oct 27: the ladder lost $6/hr on a strong Saturday): 2 offers that met the full rules in the last
    /// 30 minutes. While busy the reader uses the full rules — no weekday bar, no slow-hour ladder.
    static func isBusy(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return standardOffers.filter { now.timeIntervalSince($0.at) <= 1800 }.count >= 2
    }

    /// Today's bar when it is lower than the rules: the weekday bar on its days, unless busy.
    static func dayBar(_ rules: Rules, now: Date = Date()) -> (hourlyCents: Int, centsPerMile: Int)? {
        let weekday = Calendar.current.component(.weekday, from: now) - 1
        guard rules.weekdaySet.contains(weekday), rules.weekdayHourly < rules.hourlyTargetCents || rules.weekdayPerMile < rules.centsPerMile,
              !isBusy(now: now) else { return nil }
        return (min(rules.weekdayHourly, rules.hourlyTargetCents), min(rules.weekdayPerMile, rules.centsPerMile))
    }

    /// The bar for now, as the settings JSON value ("slowBar"), or nil when it isn't a slow hour. The steps go down from
    /// today's bar: on a weekday-bar day the first step is $21.
    static func barJSON(now: Date = Date()) -> String? {
        guard !isBusy(now: now) else { return nil }
        lock.lock(); let live = minutesWithoutGood; lock.unlock()
        let slot = slots()[slotKey(now)] ?? 0
        let step = live >= 60 ? 2 : live >= 30 ? 1 : 0
        let tier = min(3, slot + step)
        guard tier > 0 else { return nil }
        let rules = RulesStore.current
        let base = dayBar(rules, now: now)?.hourlyCents ?? rules.hourlyTargetCents
        let below = bars.filter { $0.hourlyCents < base }
        guard !below.isEmpty else { return nil }
        let bar = below[min(tier, below.count) - 1]
        let reason = step > 0 ? "no \(Rules.dollars(rules.hourlyTargetCents)) offer in \(live) min" : "usually slow at this time"
        return "{\"hourlyCents\":\(bar.hourlyCents),\"centsPerMile\":\(bar.centsPerMile),\"reason\":\"\(reason)\"}"
    }
}
