import Foundation

/// The mileage deduction rate (Earnings → Deduction). By default the IRS standard business rate for each trip's date
/// (research, Oct 24: the app still used 2024's 67¢): 70¢ in 2025, 72.5¢ for January–June 2026, 76¢ from July 1, 2026
/// (the IRS raised it mid-year for fuel prices). The driver can set their own rate in Account instead.
enum MileageRate {
    private static let key = "mileageDeductionCents"
    private static let migratedKey = "mileageDeductionIRS"

    /// The driver's own rate in cents, or nil for the IRS rate by date.
    static var custom: Int? {
        get { UserDefaults.standard.object(forKey: key) as? Int }
        set { if let newValue { UserDefaults.standard.set(newValue, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    }

    /// 67¢ was the old built-in default, not a choice: from now on that means the IRS rate.
    static func migrate() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedKey)
        if custom == 67 { custom = nil }
    }

    /// The IRS business rate in cents for a trip on `date`.
    static func irs(on date: Date) -> Double {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        switch (c.year ?? 0, c.month ?? 1) {
        case (..<2025, _): return 67
        case (2025, _): return 70
        case (2026, ..<7): return 72.5
        default: return 76
        }
    }

    /// The rate used for a trip on `date`.
    static func cents(on date: Date) -> Double { custom.map(Double.init) ?? irs(on: date) }

    /// "76¢", "72.5¢".
    static func text(_ cents: Double) -> String {
        cents.rounded() == cents ? "\(Int(cents))¢" : String(format: "%.1f¢", cents)
    }
}
