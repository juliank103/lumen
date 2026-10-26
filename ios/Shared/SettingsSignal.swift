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

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    private static func snap(_ value: Int, _ grid: [Int]) -> Int { grid.min { abs($0 - value) < abs($1 - value) } ?? value }

    /// The app: send the rules and what was learned about time.
    static func send(rules: Rules, timing: TimingStore.Timing) {
        post(prefix + "cpm.\(snap(rules.centsPerMile, perMile))")
        post(prefix + "hourly.\(snap(rules.hourlyTargetCents, hourly))")
        post(prefix + "share.\(snap(Int((timing.returnShare * 100).rounded()), shares))")
        for app in apps {
            let factor = timing.factors[app].map { snap(Int(($0 * 100).rounded()), factors) } ?? 100
            post(prefix + "factor.\(app).\(factor)")
        }
    }

    /// The reader: listen for every possible value (once per broadcast).
    static func listen() {
        var names = perMile.map { "cpm.\($0)" } + hourly.map { "hourly.\($0)" } + shares.map { "share.\($0)" }
        for app in apps { names += factors.map { "factor.\(app).\($0)" } }
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
        case "cpm", "hourly":
            var rules = defaults.data(forKey: "rules").flatMap { try? decoder.decode(Rules.self, from: $0) } ?? .defaults
            if parts.first == "cpm" { rules.centsPerMile = value } else { rules.hourlyTargetCents = value }
            defaults.set(try? encoder.encode(rules), forKey: "rules")
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
