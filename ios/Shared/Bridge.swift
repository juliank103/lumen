import UIKit

/// A second way for the app to hand its small settings to the offer reader when the App Group is gone (user, Oct 24:
/// FlareStore's signing leaves "Not shared with this install"). A named pasteboard is private to apps signed with the
/// same team, which the app and its extension always are, and needs no extra entitlement. Only small settings travel
/// here — rules, return destination, learned timing, store positions (businesses) — never offers or customer data.
enum Bridge {
    private static let name = UIPasteboard.Name("com.juliank103.mellodycopilot.bridge")
    private static func type(_ key: String) -> String { "com.juliank103.mellodycopilot.bridge." + key }

    /// The app: replaces `key`'s value, keeping the others.
    static func publish(_ key: String, _ data: Data) {
        guard let board = UIPasteboard(name: name, create: true) else { return }
        var item = board.items.first ?? [:]
        if (item[type(key)] as? Data) == data { return }
        item[type(key)] = data
        board.setItems([item], options: [:])
    }

    /// The reader: `key`'s value, if the app published one. The last value read is kept in the reader's own storage, so
    /// settings survive the pasteboard being cleared (Apple documents named pasteboards as not persistent: gone when the
    /// app quits or the phone restarts — research, Oct 24) until the app hands them over again.
    static func read(_ key: String) -> Data? {
        let cacheKey = "bridge." + key
        if let board = UIPasteboard(name: name, create: false), let data = board.data(forPasteboardType: type(key)) {
            if UserDefaults.standard.data(forKey: cacheKey) != data { UserDefaults.standard.set(data, forKey: cacheKey) }
            return data
        }
        return UserDefaults.standard.data(forKey: cacheKey)
    }
}
