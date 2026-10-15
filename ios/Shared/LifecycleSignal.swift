import Foundation

/// An order state seen on screen (core/screen-reader.js `readStatus`), sent from the offer reader to the app as a Darwin
/// notification named after the app and state — no data, no App Group needed. The app, running for the shift, turns it
/// into trip steps. Only states that move a trip are sent.
struct LifecycleSignal: Hashable {
    static let platforms = ["doordash", "uber_eats", "grubhub"]
    static let states = ["available", "heading_to_store", "at_store", "heading_to_customer", "at_customer", "delivered"]

    let platform: String
    let state: String

    var name: String { "com.juliank103.mellodycopilot.lifecycle.\(platform).\(state)" }

    static var all: [LifecycleSignal] {
        platforms.flatMap { platform in states.map { LifecycleSignal(platform: platform, state: $0) } }
    }

    init(platform: String, state: String) {
        self.platform = platform
        self.state = state
    }

    init?(name: String) {
        guard let match = Self.all.first(where: { $0.name == name }) else { return nil }
        self = match
    }

    func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}
