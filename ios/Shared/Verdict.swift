import Foundation

/// The call a notification line makes, for color coding (user, Oct 14): neon green Accept, neon red Decline,
/// yellow for everything uncertain. "Likely Accept" is green: it already passes against the longest possible return.
enum Verdict {
    case accept, decline, maybe

    init(notice: String?) {
        let text = (notice ?? "").replacingOccurrences(of: "UPDATE · ", with: "")
        if text.hasSuffix("Decline") { self = .decline }
        else if text.hasSuffix("· Accept") || text.hasPrefix("Likely Accept") { self = .accept }
        else { self = .maybe }
    }

    /// The notice's two numbers: "$1.42/mi · $31/hr · Accept" → ("$1.42/mi", "$31/hr"); heading home (Oct 28),
    /// "Home +2.5 mi · +12 min · Accept" → ("+2.5 mi", "+12 min").
    static func rates(_ notice: String?) -> (miles: String?, time: String?) {
        let parts = (notice ?? "").replacingOccurrences(of: "UPDATE · ", with: "").components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = parts.first, first.hasPrefix("Home ") {
            return (String(first.dropFirst(5)), parts.first { $0.hasSuffix(" min") })
        }
        return (parts.first { $0.hasSuffix("/mi") }, parts.first { $0.hasSuffix("/hr") })
    }

    /// Notifications can't be colored by apps, so they start with a colored dot.
    var dot: String {
        switch self {
        case .accept: return "🟢"
        case .decline: return "🔴"
        case .maybe: return "🟡"
        }
    }

    var word: String {
        switch self {
        case .accept: return "Accept"
        case .decline: return "Decline"
        case .maybe: return "Maybe"
        }
    }
}
