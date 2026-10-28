import Foundation

/// The app's settings for the reader, carried in Darwin notification names (Oct 27). Without an App Group the reader
/// was meant to get them through the bridge's named pasteboard, but that never arrives on this install: the reader kept
/// counting the whole drive back toward $/hr instead of the learned 61% (user: "Wouldn't that apply to time too?").
/// Signals do arrive (the training switch reached the reader this way), and a notification's name can carry a value:
/// "…setting.share.61". The reader listens for every value on a grid and stores what arrives in its own defaults, where
/// RulesStore and TimingStore read it. The app sends everything when the reader starts and whenever a setting changes.
enum SettingsSignal {
    private static let prefix = "com.juliank103.mellodycopilot.setting."
    private static let apps = ["doordash", "uber_eats", "grubhub"]
    /// Value grids: share of the drive back in %, time factors in hundredths (step 5), $/mi in cents (step 5), $/hr in
    /// cents (step 100). Values off the grid are rounded onto it.
    private static let shares = Array(30...100)
    private static let factors = Array(stride(from: 50, through: 300, by: 5))
    private static let perMile = Array(stride(from: 25, through: 500, by: 5))
    private static let hourly = Array(stride(from: 500, through: 10_000, by: 100))
    /// The weekday bar: $/hr in cents (step 50, for $23.50), $/mi like cpm, days as a bit mask (bit 0 = Sunday).
    private static let weekdayHourly = Array(stride(from: 1000, through: 6000, by: 50))
    private static let dayMasks = Array(0...127)

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    private static func snap(_ value: Int, _ grid: [Int]) -> Int { grid.min { abs($0 - value) < abs($1 - value) } ?? value }

    /// The app: send the rules and what was learned about time.
    static func send(rules: Rules, timing: TimingStore.Timing) {
        post(prefix + "cpm.\(snap(rules.centsPerMile, perMile))")
        post(prefix + "hourly.\(snap(rules.hourlyTargetCents, hourly))")
        post(prefix + "wdhourly.\(snap(rules.weekdayHourly, weekdayHourly))")
        post(prefix + "wdcpm.\(snap(rules.weekdayPerMile, perMile))")
        post(prefix + "wddays.\(rules.weekdayMask)")
        post(prefix + "share.\(snap(Int((timing.returnShare * 100).rounded()), shares))")
        for app in apps {
            let factor = timing.factors[app].map { snap(Int(($0 * 100).rounded()), factors) } ?? 100
            post(prefix + "factor.\(app).\(factor)")
        }
        sendDestination()
        // Slow hours: each weekday and meal time's tier (0 normal … 3 dead).
        for (key, tier) in SlowHours.slots() {
            let parts = key.split(separator: "|")
            if parts.count == 2 { post(prefix + "slot.\(parts[0]).\(parts[1]).\(max(0, min(3, tier)))") }
        }
    }

    /// The return destination in use — Home while heading home (Oct 28) — since nothing else reaches the reader on this
    /// install. Rounded to 0.001° (about 100 m) and sent as digits: "dest.lat.<place>.<digit>" and "dest.latneg.<0|1>",
    /// the same for lon, a check "dest.check.<0…96>", then "dest.mode.<0 the default | 1 a place | 2 heading home>".
    /// Signals stay on the phone. The reader uses a place once its digits match the check.
    static func sendDestination() {
        let place = ReturnDestinationStore.current
        guard let lat = place.latitude, let lon = place.longitude else { post(prefix + "dest.mode.0"); return }
        let a = Int((abs(lat) * 1000).rounded()), b = Int((abs(lon) * 1000).rounded())
        let latNeg = lat < 0 ? 1 : 0, lonNeg = lon < 0 ? 1 : 0
        post(prefix + "dest.latneg.\(latNeg)")
        post(prefix + "dest.lonneg.\(lonNeg)")
        var scale = 1
        for i in 0..<6 {
            post(prefix + "dest.lat.\(i).\(a / scale % 10)")
            post(prefix + "dest.lon.\(i).\(b / scale % 10)")
            scale *= 10
        }
        post(prefix + "dest.check.\(check(latNeg, a, lonNeg, b))")
        post(prefix + "dest.mode.\(ReturnDestinationStore.headingHome ? 2 : 1)")
    }

    private static func check(_ latNeg: Int, _ a: Int, _ lonNeg: Int, _ b: Int) -> Int { (a * 31 + b * 7 + latNeg * 3 + lonNeg * 5) % 97 }

    /// The reader's destination digits so far (key "lat.3", "latneg", "check", "mode", …).
    private static var pending: [String: Int] = [:]
    private static let pendingLock = NSLock()

    private static func receivedDestination(_ parts: [String], _ value: Int) {
        pendingLock.lock(); defer { pendingLock.unlock() }
        pending[parts.dropFirst().dropLast().joined(separator: ".")] = value
        guard let mode = pending["mode"] else { return }
        if mode == 0 { return ReturnDestinationStore.received(.homeBase, headingHome: false) }
        var a = 0, b = 0, scale = 1
        for i in 0..<6 {
            guard let x = pending["lat.\(i)"], let y = pending["lon.\(i)"] else { return }
            a += x * scale; b += y * scale; scale *= 10
        }
        guard let latNeg = pending["latneg"], let lonNeg = pending["lonneg"], pending["check"] == check(latNeg, a, lonNeg, b) else { return }
        let place = ReturnDestination(name: mode == 2 ? "Home" : "Return spot", latitude: Double(a) / 1000 * (latNeg == 1 ? -1 : 1),
                                      longitude: Double(b) / 1000 * (lonNeg == 1 ? -1 : 1), query: nil)
        ReturnDestinationStore.received(place, headingHome: mode == 2)
    }

    /// The reader: listen for every possible value (once per broadcast).
    static func listen() {
        var names = perMile.map { "cpm.\($0)" } + hourly.map { "hourly.\($0)" } + shares.map { "share.\($0)" }
        names += weekdayHourly.map { "wdhourly.\($0)" } + perMile.map { "wdcpm.\($0)" } + dayMasks.map { "wddays.\($0)" }
        for app in apps { names += factors.map { "factor.\(app).\($0)" } }
        for day in 0..<7 { for part in ["lunch", "dinner", "other"] { names += (0...3).map { "slot.\(day).\(part).\($0)" } } }
        for i in 0..<6 { for d in 0...9 { names += ["dest.lat.\(i).\(d)", "dest.lon.\(i).\(d)"] } }
        names += (0...1).flatMap { ["dest.latneg.\($0)", "dest.lonneg.\($0)"] } + (0...96).map { "dest.check.\($0)" } + (0...2).map { "dest.mode.\($0)" }
        for name in names {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
                guard let full = name?.rawValue as String? else { return }
                SettingsSignal.received(String(full.dropFirst(SettingsSignal.prefix.count)))
            }, (prefix + name) as CFString, nil, .deliverImmediately)
        }
    }

    /// Stored where RulesStore and TimingStore look in the reader (its own defaults, keys "rules" and "timing").
    private static func received(_ setting: String) {
        let parts = setting.split(separator: ".").map(String.init)
        guard let last = parts.last, let value = Int(last) else { return }
        let defaults = UserDefaults.standard, decoder = JSONDecoder(), encoder = JSONEncoder()
        switch parts.first {
        case "dest":
            receivedDestination(parts, value)
        case "cpm", "hourly", "wdhourly", "wdcpm", "wddays":
            var rules = defaults.data(forKey: "rules").flatMap { try? decoder.decode(Rules.self, from: $0) } ?? .defaults
            switch parts.first {
            case "cpm": rules.centsPerMile = value
            case "hourly": rules.hourlyTargetCents = value
            case "wdhourly": rules.weekdayHourlyCents = value
            case "wdcpm": rules.weekdayCentsPerMile = value
            default: rules.weekdayDays = (0..<7).filter { value & (1 << $0) != 0 }
            }
            defaults.set(try? encoder.encode(rules), forKey: "rules")
        case "slot" where parts.count == 4:
            var slots = SlowHours.slots()
            slots[parts[1] + "|" + parts[2]] = value
            defaults.set(slots, forKey: SlowHours.storeKey)
        case "share", "factor":
            var timing = defaults.data(forKey: "timing").flatMap { try? decoder.decode(TimingStore.Timing.self, from: $0) } ?? TimingStore.Timing()
            if parts.first == "share" { timing.returnShare = Double(value) / 100 }
            else if parts.count == 3 { timing.factors[parts[1]] = Double(value) / 100 }
            defaults.set(try? encoder.encode(timing), forKey: "timing")
        default:
            return
        }
        // The app's Diagnostics shows "Settings reach the reader" from this.
        Signal.bridgeRead.post()
    }
}
