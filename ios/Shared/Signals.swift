import Foundation

// Darwin notifications carry no data and need no App Group, so they show the app whether the capture extension is
// alive even when the install has no shared container (free Apple ID via Sideloadly) or notifications are off.
enum Signal: String, CaseIterable {
    // `selfTest` is posted by the app itself to prove the signal path works on this phone.
    // `stopReading` goes the other way: the app asks the reader to end the screen broadcast (End shift, Oct 23).
    // `bridgeRead`: the reader got the app's settings through the bridge (no App Group, Oct 24).
    // `aiProbe`: the reader finished an Apple Intelligence test and saved the result to the bridge (Oct 24).
    case selfTest, loaded, started, frame, offer, readerFailed, finished, stopReading, bridgeRead, aiProbe

    var name: String { "com.juliank103.mellodycopilot.signal." + rawValue }

    func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}
