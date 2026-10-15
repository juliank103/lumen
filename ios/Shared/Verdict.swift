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
