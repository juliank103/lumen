import Foundation

/// Where the user drives back to after each order: the return leg of every offer and the "already driving back"
/// credit. Default __HOME_NAME__; changeable in the app (user, Oct 14, 2026).
struct ReturnDestination: Codable, Equatable, Identifiable {
    var id: String { latitude.map { String(format: "%@|%.5f,%.5f", name, $0, longitude ?? 0) } ?? name + "|" + (query ?? "") }
    let name: String
    /// The exact place picked in the app. Nil for the default, which Apple Maps resolves from `query`.
    let latitude: Double?
    let longitude: Double?
    let query: String?

    static let homeBase = ReturnDestination(name: "__HOME_NAME__", latitude: nil, longitude: nil, query: "__HOME_QUERY__")
    var isDefault: Bool { self == .homeBase }

    func renamed(_ newName: String) -> ReturnDestination {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReturnDestination(name: trimmed.isEmpty ? name : trimmed, latitude: latitude, longitude: longitude, query: query)
    }
}

/// The app writes the choice to the App Group; the capture extension reads it before every return lookup, so a change
/// applies from the next offer without restarting the broadcast. The app also keeps its own copy, but without an App
/// Group the extension cannot see it and keeps using __HOME_NAME__ (the app says so). Stored on the phone only.
enum ReturnDestinationStore {
    private struct State: Codable {
        var current: ReturnDestination
        var saved: [ReturnDestination]
    }
    private static let fileName = "return-destination.json"
    private static let localKey = "returnDestinationState"

    private static func sharedURL() -> URL? { try? AppGroup.container().appendingPathComponent(fileName) }

    private static func load() -> State {
        let decoder = JSONDecoder()
        if let url = sharedURL(), let data = try? Data(contentsOf: url), let state = try? decoder.decode(State.self, from: data) { return state }
        if let data = UserDefaults.standard.data(forKey: localKey), let state = try? decoder.decode(State.self, from: data) { return state }
        return State(current: .homeBase, saved: [])
    }

    @discardableResult
    private static func save(_ state: State) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        UserDefaults.standard.set(data, forKey: localKey)
        guard let url = sharedURL() else { return false }
        return (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }

    static var current: ReturnDestination { load().current }
    /// Places the user added, most recent first (__HOME_NAME__ is always available and not listed here).
    static var saved: [ReturnDestination] { load().saved }
    /// Whether the offer reader can see the choice.
    static var isShared: Bool { sharedURL() != nil }

    /// Makes `destination` the return destination and remembers it. Returns whether the reader can see it.
    @discardableResult
    static func select(_ destination: ReturnDestination) -> Bool {
        var state = load()
        state.current = destination
        if !destination.isDefault {
            state.saved.removeAll { $0.latitude == destination.latitude && $0.longitude == destination.longitude }
            state.saved.insert(destination, at: 0)
            state.saved = Array(state.saved.prefix(8))
        }
        return save(state)
    }

    static func remove(_ destination: ReturnDestination) {
        var state = load()
        state.saved.removeAll { $0 == destination }
        if state.current == destination { state.current = .homeBase }
        save(state)
    }
}
