import ActivityKit
import AppIntents
import Foundation

/// The shift on the lock screen and in the Dynamic Island (user, Oct 21): one Live Activity for the whole shift that
/// shows, by priority, the reader having stopped, a new offer's verdict (45 s), the trip, or the shift's earnings and
/// goal. Compiled into the app and the widget extension. Button taps run in the app (LiveActivityIntent).
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "readerOff", "offer", "trip", or "idle".
        var mode: String = "trip"
        /// The trip's start (trip) or the shift's (idle), for the running clock.
        var startedAt: Date
        var paceText: String
        var payText: String
        var orderCount: Int
        var nextLabel: String?
        var nextActionId: String?
        // Idle: the shift so far and the day's goal.
        var earningsText: String? = nil
        var hourlyText: String? = nil
        var milesText: String? = nil
        var goalProgress: Double? = nil
        var goalText: String? = nil
        // Offer: verdict ("accept", "decline", "maybe"), $/mi, $/hr, pay, store, and when the decision time ends.
        var verdict: String? = nil
        var perMileText: String? = nil
        var perHourText: String? = nil
        var offerPayText: String? = nil
        var offerStore: String? = nil
        var offerUntil: Date? = nil
    }
    var tripId: String
}

/// "Next step" from the Live Activity. Runs in the app's process, which records the step like a tap.
struct TripStepIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Record the next order step"
    static var openAppWhenRun = false

    @Parameter(title: "Step") var actionId: String

    init() {}
    init(actionId: String) { self.actionId = actionId }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let id = actionId
        await MainActor.run {
            if let action = TripStore.shared.active?.actions.first(where: { $0.id == id }) { TripStore.shared.perform(action) }
        }
        #endif
        return .result()
    }
}

/// "Undo" from the Live Activity.
struct TripUndoIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Undo the last order step"
    static var openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { TripStore.shared.undo() }
        #endif
        return .result()
    }
}
