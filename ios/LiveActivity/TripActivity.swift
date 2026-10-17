import ActivityKit
import AppIntents
import Foundation

/// The active trip on the lock screen and in the Dynamic Island (review item): timer, pace, and the next step as a
/// button. Compiled into the app and the widget extension. Button taps run in the app (LiveActivityIntent).
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        var paceText: String
        var payText: String
        var orderCount: Int
        var nextLabel: String?
        var nextActionId: String?
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
