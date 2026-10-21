import Foundation
import Combine

// Counts signals from the capture extension while the app is open (Darwin notifications are not queued).
final class ExtensionSignals: ObservableObject {
    static let offerReceived = Notification.Name("lumen.offerReceived")
    @Published private(set) var selfTestReceived = false
    @Published private(set) var loadedAt: Date?
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var frames = 0
    @Published private(set) var offers = 0
    @Published private(set) var readerFailed = false
    @Published private(set) var finishedAt: Date?

    init() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for signal in Signal.allCases {
            CFNotificationCenterAddObserver(center, observer, { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let me = Unmanaged<ExtensionSignals>.fromOpaque(observer).takeUnretainedValue()
                let value = name.rawValue as String
                DispatchQueue.main.async { me.receive(value) }
            }, signal.name as CFString, nil, .deliverImmediately)
        }
        // Order states read off the delivery apps' screens (one Darwin name per app and state).
        for signal in LifecycleSignal.all {
            CFNotificationCenterAddObserver(center, observer, { _, _, name, _, _ in
                guard let name, let signal = LifecycleSignal(name: name.rawValue as String) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { LifecycleSync.shared.received(signal) } }
            }, signal.name as CFString, nil, .deliverImmediately)
        }
        Signal.selfTest.post()
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }

    private func receive(_ name: String) {
        guard let signal = Signal.allCases.first(where: { $0.name == name }) else { return }
        let now = Date()
        switch signal {
        case .selfTest: selfTestReceived = true
        case .loaded: loadedAt = now
        case .started:
            startedAt = now; finishedAt = nil; readerFailed = false
            MainActor.assumeIsolated { ShiftStore.shared.startIfNeeded() }
        case .frame: frames += 1; lastFrameAt = now
        case .offer:
            offers += 1
            NotificationCenter.default.post(name: Self.offerReceived, object: nil)
        case .readerFailed: readerFailed = true
        case .finished:
            finishedAt = now
            MainActor.assumeIsolated {
                ReadingMonitor.shared.readingFinished()
                ShiftStore.shared.readingStopped()
            }
        }
    }
}
