import SwiftUI

// Visual language (user, Oct 21, approved preview): dark-first; purple only on what you can tap; verdict colors only on
// verdicts, always with an icon (they differ in lightness, not hue alone). Verdict chips use dark text.
enum Theme {
    static let purple = Color(red: 0.486, green: 0.361, blue: 1.0)      // #7C5CFF, the action color
    static let purpleSoft = Color(red: 0.486, green: 0.361, blue: 1.0).opacity(0.16)
    static let neonGreen = Color(red: 0.239, green: 0.863, blue: 0.518) // #3DDC84 Accept
    static let neonRed = Color(red: 1.0, green: 0.42, blue: 0.357)      // #FF6B5B Decline
    static let neonYellow = Color(red: 1.0, green: 0.788, blue: 0.235)  // #FFC93C Check
    static let ground = Color(red: 0.043, green: 0.043, blue: 0.063)    // #0B0B10
    static let card = Color(red: 0.082, green: 0.082, blue: 0.114)      // #15151D
    static let raised = Color(red: 0.133, green: 0.133, blue: 0.176)    // #22222D
    static let track = Color(red: 0.165, green: 0.165, blue: 0.212)     // #2A2A36
    static let secondaryText = Color(red: 0.639, green: 0.631, blue: 0.702) // #A3A1B3

    static func color(_ verdict: Verdict) -> Color {
        switch verdict {
        case .accept: return neonGreen
        case .decline: return neonRed
        case .maybe: return neonYellow
        }
    }

    static func appName(_ platform: String) -> String {
        ["doordash": "DoorDash", "uber_eats": "Uber Eats", "grubhub": "Grubhub", "uber": "Uber", "instacart": "Instacart", "lyft": "Lyft",
         "spark": "Spark", "shipt": "Shipt", "amazon_flex": "Amazon Flex"][platform]
            ?? platform.replacingOccurrences(of: "_", with: " ").capitalized
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
