import SwiftUI

// Dasher-app look in purple instead of DoorDash red (user, Oct 14). Verdicts in neon: green Accept, red Decline,
// yellow for anything uncertain. Neon chips use black text so they read in light and dark mode.
enum Theme {
    static let purple = Color(red: 0.42, green: 0.22, blue: 0.96)      // primary, like Dasher's red
    static let purpleSoft = Color(red: 0.42, green: 0.22, blue: 0.96).opacity(0.12)
    static let neonGreen = Color(red: 0.22, green: 1.0, blue: 0.08)     // #39FF14
    static let neonRed = Color(red: 1.0, green: 0.19, blue: 0.19)       // #FF3131
    static let neonYellow = Color(red: 1.0, green: 0.94, blue: 0.12)    // #FFF01F
    static let card = Color(.secondarySystemBackground)

    static func color(_ verdict: Verdict) -> Color {
        switch verdict {
        case .accept: return neonGreen
        case .decline: return neonRed
        case .maybe: return neonYellow
        }
    }

    static func appName(_ platform: String) -> String {
        ["doordash": "DoorDash", "uber_eats": "Uber Eats", "grubhub": "Grubhub"][platform] ?? platform
    }
}

/// The verdict as a neon pill: "$1.21/mi · $27/hr · Accept".
struct VerdictChip: View {
    let notice: String?
    var large = false

    var body: some View {
        let verdict = Verdict(notice: notice)
        Text(notice ?? "Reading…")
            .font(large ? .headline.weight(.heavy) : .caption.weight(.bold))
            .foregroundStyle(.black)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, large ? 14 : 9)
            .padding(.vertical, large ? 10 : 5)
            .background(Theme.color(verdict), in: Capsule())
    }
}

/// A small app badge like the Dasher app's platform tags.
struct PlatformBadge: View {
    let platform: String
    var body: some View {
        Text(Theme.appName(platform).uppercased())
            .font(.caption2.weight(.heavy)).tracking(0.5)
            .foregroundStyle(Theme.purple)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.purpleSoft, in: Capsule())
    }
}

extension View {
    func dasherCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
