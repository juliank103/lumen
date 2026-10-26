import UIKit

/// Training screens travel from the reader to the app on their own named pasteboard (Oct 25). The reader must not
/// write to Photos itself: loading Photos inside the ~50 MB broadcast extension got it killed on the first offer, and no
/// verdicts went out (user: "Turning it off fixed it"). Each screen is one pasteboard item, appended without reading
/// the others; the app saves them to Photos when it's next in front and clears the board.
enum TrainingHandoff {
    static let name = UIPasteboard.Name("com.juliank103.mellodycopilot.training")
    static let imageType = "public.jpeg"
    static let nameType = "com.juliank103.mellodycopilot.training-name"
    /// Screens waiting for the app at most; past this the reader skips until the app takes them.
    static let maxWaiting = 30

    /// The reader: hand over one screen. Returns how many are waiting, or nil if the board is full or missing.
    static func add(_ jpeg: Data, name fileName: String) -> Int? {
        guard let board = UIPasteboard(name: name, create: true), board.numberOfItems < maxWaiting else { return nil }
        board.addItems([[imageType: jpeg, nameType: Data(fileName.utf8)]])
        return board.numberOfItems
    }

    static var waiting: Int { UIPasteboard(name: name, create: false)?.numberOfItems ?? 0 }

    /// The app: the screens waiting (image, file name), and a way to remove exactly those once they're saved.
    static func take() -> (screens: [(Data, String)], done: () -> Void) {
        guard let board = UIPasteboard(name: name, create: true) else { return ([], {}) }
        let items = board.items
        let screens = items.compactMap { item -> (Data, String)? in
            guard let data = item[imageType] as? Data else { return nil }
            return (data, (item[nameType] as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "__APP_NAME__ training.jpg")
        }
        return (screens, {
            // Anything the reader added meanwhile stays.
            board.items = Array(board.items.dropFirst(items.count))
        })
    }
}
