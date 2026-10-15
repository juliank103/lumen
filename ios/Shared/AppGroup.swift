import Foundation

// Shared container between the app and the capture extension. Re-signing tools can change or drop the App Group:
// a free Apple ID through Sideloadly left it unavailable on the user's phone (October 13, 2026). Everything that
// uses this must keep working without it; offers also travel inside the notifications themselves.
enum AppGroup {
    enum StorageError: Error { case appGroupUnavailable }

    static func container() throws -> URL {
        var candidates: [String] = []
        if let group = Bundle.main.object(forInfoDictionaryKey: "CopilotAppGroup") as? String { candidates.append(group) }
        // AltStore/SideStore record the groups they actually registered under this key.
        if let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] { candidates += groups }
        for group in candidates {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) { return url }
        }
        throw StorageError.appGroupUnavailable
    }
}
