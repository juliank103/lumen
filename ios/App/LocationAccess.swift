import CoreLocation

// The app only asks for permission; the capture extension reads the position to credit the drive back to
// __HOME_NAME__ and to bound returns. "Always" may be needed because the broadcast runs while other apps are open.
// Positions are never stored.
enum LocationAccess {
    static let manager = CLLocationManager()

    static func requestAlways() { manager.requestAlwaysAuthorization() }

    static var statusText: String {
        switch manager.authorizationStatus {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "while using — tap “Allow location always”"
        case .denied: return "off — Settings › __APP_FULL__ › Location"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }
}
