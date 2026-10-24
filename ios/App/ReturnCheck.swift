import MapKit

/// The real drive back for each order (user, Oct 23: reader upgrade 1 — the reader grades itself). At the order's last
/// drop-off the phone knows where it is; Apple Maps routes from there to your return destination, and only the miles are
/// kept on the order (`actualReturnMilliMiles`). The position is dropped right after — no customer location is stored.
/// Breakdown compares it with the return the offer's verdict used.
@MainActor
enum ReturnCheck {
    /// Where you were on reaching each order's last drop-off, until the route is worked out (memory only).
    private static var lastDropoff: [String: CLLocation] = [:]

    static func arrivedAtLastDropoff(_ offerId: String) {
        if let here = fresh() { lastDropoff[offerId] = here }
    }

    static func orderCompleted(_ offerId: String) {
        let from = lastDropoff.removeValue(forKey: offerId) ?? fresh()
        guard let from, let home = ShiftStore.shared.homeCoordinate else { return }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: home))
        request.transportType = .automobile
        MKDirections(request: request).calculate { response, _ in
            guard let meters = response?.routes.first?.distance else { return }
            let milliMiles = Int((meters / 1609.344 * 1000).rounded())
            MainActor.assumeIsolated { TripStore.shared.setActualReturn(offerId, milliMiles: milliMiles) }
        }
    }

    /// A recent, reasonably precise fix (≤ 3 minutes old, ≤ 150 m).
    private static func fresh() -> CLLocation? {
        guard let here = ShiftStore.shared.lastLocation, Date().timeIntervalSince(here.timestamp) < 180,
              here.horizontalAccuracy >= 0, here.horizontalAccuracy <= 150 else { return nil }
        return here
    }
}
