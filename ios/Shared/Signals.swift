import Foundation

// Darwin notifications carry no data and need no App Group, so they show the app whether the capture extension is
// alive even when the install has no shared container (free Apple ID via Sideloadly) or notifications are off.
enum Signal: String, CaseIterable {
    // `selfTest` is posted by the app itself to prove the signal path works on this phone.
    case selfTest, loaded, started, frame, offer, readerFailed, finished

    var name: String { "com.juliank103.mellodycopilot.signal." + rawValue }

    func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}
