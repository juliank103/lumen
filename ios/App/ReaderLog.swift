import Foundation
import CallKit
import UIKit

/// When screen reading started, stopped, paused or ran short of memory, and whether a phone call was on (user, Oct 27:
/// "the reader unexplainably stopping and being buggy when trying to start it back up … I think it happened more when I
/// was on phone calls"). Only times and kinds: no numbers, names or screen text. In the export as "readerLog".
@MainActor
final class ReaderLog: NSObject, ObservableObject, CXCallObserverDelegate {
    static let shared = ReaderLog()

    struct Entry: Codable, Identifiable {
        var id: Date { at }
        let at: Date
        let event: String
        var detail: String?
    }

    @Published private(set) var entries: [Entry] = []
    /// The last frame the reader said it read, while __APP_NAME__ was running.
    private(set) var lastFrameAt: Date?
    private let calls = CXCallObserver()
    /// Each call's last state, so a call's repeated updates make one entry per change.
    private var callStates: [UUID: String] = [:]

    private override init() {
        super.init()
        entries = Self.load()
        calls.setDelegate(self, queue: .main)
    }

    var onCall: Bool { calls.calls.contains { !$0.hasEnded } }

    func note(_ event: String, _ detail: String? = nil, at now: Date = Date()) {
        var text = detail
        if onCall, !event.hasPrefix("call_") { text = (text.map { $0 + "; " } ?? "") + "on a call" }
        entries.append(Entry(at: now, event: event, detail: text))
        if entries.count > 1000 { entries.removeFirst(entries.count - 1000) }
        save()
    }

    func frameRead(at now: Date = Date()) { lastFrameAt = now }

    /// Seconds since the reader last read a frame, for the entries ("last frame 4 s before").
    func frameAge(at now: Date = Date()) -> String {
        lastFrameAt.map { "last frame \(Int(now.timeIntervalSince($0))) s before" } ?? "no frame seen"
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let state = call.hasEnded ? "call_ended" : call.hasConnected ? "call_connected" : call.isOutgoing ? "call_dialing" : "call_ringing"
        let id = call.uuid, ended = call.hasEnded
        MainActor.assumeIsolated {
            guard callStates[id] != state else { return }
            callStates[id] = ended ? nil : state
            note(state, UIScreen.main.isCaptured ? "screen captured" : "screen not captured")
        }
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(entries)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    private static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("reader-log.json")
    }

    private static func load() -> [Entry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func save() {
        guard let url = Self.url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(entries).write(to: url, options: .atomic)
    }
}
