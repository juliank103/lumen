import Foundation
import CoreLocation
import MapKit

/// One shift: online from start to end. Miles are totals by kind; the route itself is never stored.
struct Shift: Codable, Identifiable, Equatable {
    let id: String
    var startedAt: Date
    var endedAt: Date?
    /// Reading stopped with no trip running; a restart within 30 minutes continues this shift.
    var pausedAt: Date?
    /// Meters by kind: toPickup, delivery (on a trip), driveBack (trip ended → return destination), reposition (other).
    var meters: [String: Double]
    var goalCents: Int?
    /// Totals saved when the shift ended (core/shift.js output).
    var finalMetrics: String?
    /// The same meters split by clock hour ("<hour start, epoch seconds>": kind → meters), so a shift crossing midnight
    /// splits between days on the week view. Older shifts have none (their miles count on their start day).
    var buckets: [String: [String: Double]]? = nil
}

/// Shifts start automatically when offer reading starts (or the first order is accepted) and end when reading stops
/// with no trip running (a restart within 30 minutes continues the shift). While a shift is on, the app tracks miles in
/// the background (blue location indicator) and sorts each mile by what the driver was doing — from the trips ticked
/// in the app. Totals, rates, and the goal come from core/shift.js.
@MainActor
final class ShiftStore: ObservableObject {
    static let shared = ShiftStore()

    @Published private(set) var current: Shift?
    @Published private(set) var history: [Shift] = []
    @Published private(set) var metrics: ShiftMetrics?
    @Published private(set) var defaultGoalCents: Int?

    static let resumeWindow: TimeInterval = 30 * 60
    private let tracker = MileTracker()
    private(set) var lastLocation: CLLocation?
    private var drivingBack = false
    private var closestToHome: CLLocationDistance?
    private var home: (name: String, coordinate: CLLocationCoordinate2D)?
    private var lastSave = Date.distantPast
    private var timer: Timer?

    private init() {
        defaultGoalCents = UserDefaults.standard.object(forKey: "shiftGoalCents") as? Int
        if PreviewData.isActive {
            current = PreviewData.shift
            history = PreviewData.earlierDays.shifts
            refreshMetrics()
            return
        }
        load()
        tracker.onMove = { [weak self] location, meters in
            MainActor.assumeIsolated { self?.record(location, meters: meters) }
        }
        finalizeIfExpired()
        if let current, current.pausedAt == nil { tracker.start(); resolveHome() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { ShiftStore.shared.tick() }
        }
        refreshMetrics()
    }

    /// The shift shown on screen: the running one, else the last one.
    var shown: Shift? { current ?? history.last }

    // MARK: Lifecycle

    func startIfNeeded(at now: Date = Date()) {
        guard !PreviewData.isActive else { return }
        finalizeIfExpired(now)
        if var shift = current {
            if shift.pausedAt != nil {
                shift.pausedAt = nil
                current = shift
                save(force: true)
                tracker.start()
            }
            return
        }
        current = Shift(id: "shift-\(Int(now.timeIntervalSince1970))", startedAt: now, endedAt: nil, pausedAt: nil, meters: [:],
                        goalCents: defaultGoalCents, finalMetrics: nil)
        drivingBack = false
        tracker.start()
        resolveHome()
        save(force: true)
        refreshMetrics()
        TripActivityController.update(TripStore.shared.active) // The shift's Live Activity (Dynamic Island).
    }

    /// `exact`: end at `now` as given (the driver set the end time), not at the pause.
    func end(at now: Date = Date(), exact: Bool = false) {
        guard var shift = current else { return }
        shift.endedAt = exact ? min(Date(), max(now, shift.startedAt.addingTimeInterval(60))) : shift.pausedAt ?? now
        shift.pausedAt = nil
        current = nil
        shift.finalMetrics = metricsJSON(for: shift, now: shift.endedAt ?? now)
        history.append(shift)
        if history.count > 500 { history.removeFirst(history.count - 500) }
        tracker.stop()
        save(force: true)
        refreshMetrics()
        TripActivityController.update(TripStore.shared.active)
    }

    /// Reading stopped. With no trip running the shift pauses (and ends after 30 minutes); during a trip it continues.
    func readingStopped(at now: Date = Date()) {
        guard var shift = current, shift.pausedAt == nil, TripStore.shared.active == nil else { return }
        shift.pausedAt = now
        current = shift
        tracker.stop()
        save(force: true)
    }

    func finalizeIfExpired(_ now: Date = Date()) {
        if let paused = current?.pausedAt, now.timeIntervalSince(paused) > Self.resumeWindow { end(at: paused) }
    }

    /// The last order of a trip ended: miles from here are the drive back until the return destination is reached.
    func tripEnded() {
        drivingBack = true
        closestToHome = nil
    }

    func setGoal(_ cents: Int?) {
        let value = cents.flatMap { $0 > 0 ? $0 : nil }
        defaultGoalCents = value
        UserDefaults.standard.set(value, forKey: "shiftGoalCents")
        if var shift = current { shift.goalCents = value; current = shift; save(force: true) }
        refreshMetrics()
    }

    // MARK: Miles

    private func record(_ location: CLLocation, meters: Double) {
        lastLocation = location
        AutoSteps.shared.update(location)
        guard var shift = current, shift.pausedAt == nil, meters > 0 else { return }
        let kind = kind(at: location)
        shift.meters[kind, default: 0] += meters
        let hour = String(Int(location.timestamp.timeIntervalSince1970 / 3600) * 3600)
        var buckets = shift.buckets ?? [:]
        buckets[hour, default: [:]][kind, default: 0] += meters
        shift.buckets = buckets
        current = shift
        save()
    }

    /// What this stretch of driving was: on a trip (to the first store, then delivery), driving back after a trip, or
    /// repositioning. The drive back ends at the return destination, or when the driver heads away from it (> 0.5 mi
    /// farther than the closest point reached), after which miles count as repositioning.
    private func kind(at location: CLLocation) -> String {
        if let trip = TripStore.shared.active {
            return trip.steps.contains { $0.kind == .arrivedStore } ? "delivery" : "toPickup"
        }
        guard drivingBack else { return "reposition" }
        guard let home = currentHome() else { return "driveBack" }
        let distance = location.distance(from: CLLocation(latitude: home.latitude, longitude: home.longitude))
        if distance < 400 { drivingBack = false; return "driveBack" }
        let closest = min(closestToHome ?? distance, distance)
        closestToHome = closest
        if distance > closest + 800 { drivingBack = false; return "reposition" }
        return "driveBack"
    }

    private func currentHome() -> CLLocationCoordinate2D? {
        let destination = ReturnDestinationStore.current
        if let latitude = destination.latitude, let longitude = destination.longitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        if let home, home.name == destination.name { return home.coordinate }
        resolveHome()
        return nil
    }

    private func resolveHome() {
        let destination = ReturnDestinationStore.current
        guard destination.latitude == nil, home?.name != destination.name else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = destination.query ?? destination.name
        MKLocalSearch(request: request).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            MainActor.assumeIsolated { ShiftStore.shared.home = (destination.name, item.placemark.coordinate) }
        }
    }

    /// Every 5 s: totals, parked-GPS power saving, waiting checks for arrival detection (GPS is silent while parked),
    /// and the "reading stopped" alert.
    private func tick(now: Date = Date()) {
        refreshMetrics(now: now)
        guard current != nil, current?.pausedAt == nil else { return }
        tracker.idleCheck()
        if let here = lastLocation, now.timeIntervalSince(here.timestamp) > 8 {
            AutoSteps.shared.update(CLLocation(coordinate: here.coordinate, altitude: here.altitude, horizontalAccuracy: here.horizontalAccuracy,
                                               verticalAccuracy: here.verticalAccuracy, course: -1, speed: 0, timestamp: now))
        }
        ReadingMonitor.shared.check(now: now)
    }

    // MARK: Totals

    func refreshMetrics(now: Date = Date()) {
        finalizeIfExpired(now)
        guard let shift = shown else { metrics = nil; return }
        let text = shift.endedAt != nil && shift.finalMetrics != nil ? shift.finalMetrics : metricsJSON(for: shift, now: now)
        let decoded = ShiftEngine.decode(ShiftMetrics.self, text)
        if decoded != metrics { metrics = decoded }
    }

    /// A delivered order as timed on its shift's clock (computed fresh, so shifts saved before build 54 have it too).
    func completion(for offerId: String, acceptedAt: Date) -> ShiftMetrics.Completion? {
        let now = Date()
        guard let shift = (history + [current].compactMap { $0 }).last(where: {
            acceptedAt >= $0.startedAt.addingTimeInterval(-60) && acceptedAt <= ($0.endedAt ?? now)
        }) else { return nil }
        return ShiftEngine.decode(ShiftMetrics.self, metricsJSON(for: shift, now: shift.endedAt ?? now))?
            .completions?.first { $0.offerId == offerId }
    }

    func metrics(for shift: Shift) -> ShiftMetrics? {
        ShiftEngine.decode(ShiftMetrics.self, shift.finalMetrics ?? metricsJSON(for: shift, now: shift.endedAt ?? Date()))
    }

    func metricsJSON(for shift: Shift, now: Date) -> String? {
        let store = TripStore.shared
        let from = shift.startedAt.addingTimeInterval(-3600)
        let trips = (store.history + [store.active].compactMap { $0 }).filter { ($0.endedAt ?? now) >= from }
        var input = shift
        input.finalMetrics = nil
        return ShiftEngine.call("shiftMetricsJSON", [ShiftEngine.json(encodable: input), ShiftEngine.json(encodable: trips),
                                                     ShiftEngine.json(ISO8601DateFormatter().string(from: now)),
                                                     ShiftEngine.json(ShiftEngine.offsetMinutes)])
    }

    // MARK: Storage

    private struct Saved: Codable { var current: Shift?; var history: [Shift] }

    private var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("shifts.json")
    }

    // MARK: Editing hours

    /// Changes a shift's times (user, Oct 15: "edit hours"). The running shift's start can be moved; a past shift's
    /// start and end. Totals are recalculated.
    func updateShift(_ id: String, start: Date, end: Date?, now: Date = Date()) {
        if var shift = current, shift.id == id {
            shift.startedAt = min(start, now)
            current = shift
        } else if let index = history.firstIndex(where: { $0.id == id }) {
            var shift = history[index]
            shift.startedAt = min(start, now)
            if let end { shift.endedAt = min(now, max(end, shift.startedAt.addingTimeInterval(60))) }
            shift.finalMetrics = metricsJSON(for: shift, now: shift.endedAt ?? now)
            history[index] = shift
            history.sort { $0.startedAt < $1.startedAt }
        }
        save(force: true)
        refreshMetrics()
    }

    func deleteShift(_ id: String) {
        history.removeAll { $0.id == id }
        save(force: true)
        refreshMetrics()
    }

    /// A shift worked without __APP_NAME__ running (no miles recorded; orders ticked in that time count toward it).
    /// Miles typed in for a past shift (user, Oct 15: edit a shift's details): orders → delivery, other → repositioning.
    /// The per-hour split is dropped, so its miles count on the day it started.
    func setMiles(_ id: String, orderMiles: Double, otherMiles: Double) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        var shift = history[index]
        shift.meters = ["delivery": max(0, orderMiles) * 1609.344, "reposition": max(0, otherMiles) * 1609.344]
        shift.buckets = nil
        shift.finalMetrics = metricsJSON(for: shift, now: shift.endedAt ?? Date())
        history[index] = shift
        save(force: true)
        refreshMetrics()
    }

    /// A shift added by hand, with the miles the driver entered (orders → delivery, other → repositioning).
    func addShift(start: Date, end: Date, orderMiles: Double = 0, otherMiles: Double = 0) {
        var meters: [String: Double] = [:]
        if orderMiles > 0 { meters["delivery"] = orderMiles * 1609.344 }
        if otherMiles > 0 { meters["reposition"] = otherMiles * 1609.344 }
        var shift = Shift(id: "shift-manual-\(Int(start.timeIntervalSince1970))", startedAt: start, endedAt: max(end, start.addingTimeInterval(60)),
                          pausedAt: nil, meters: meters, goalCents: nil, finalMetrics: nil)
        shift.finalMetrics = metricsJSON(for: shift, now: shift.endedAt ?? end)
        history.append(shift)
        history.sort { $0.startedAt < $1.startedAt }
        save(force: true)
        refreshMetrics()
    }

    /// Past shifts keep the totals they ended with; after an order is deleted or its pay corrected, redo the totals of
    /// the shifts around it.
    func recomputeFinals(near date: Date) {
        var changed = false
        for index in history.indices {
            let shift = history[index]
            guard shift.startedAt.addingTimeInterval(-3600) <= date, (shift.endedAt ?? Date()).addingTimeInterval(3600) >= date else { continue }
            history[index].finalMetrics = metricsJSON(for: shift, now: shift.endedAt ?? Date())
            changed = true
        }
        if changed { save(force: true) }
        refreshMetrics()
    }

    // MARK: Backup restore and demo data

    /// Adds finished shifts that aren't here yet. Returns how many were added.
    @discardableResult
    func importShifts(_ shifts: [Shift]) -> Int {
        let known = Set(history.map(\.id) + [current?.id].compactMap { $0 })
        let added = shifts.filter { !known.contains($0.id) && $0.endedAt != nil }
        guard !added.isEmpty else { return 0 }
        history = (history + added).sorted { $0.startedAt < $1.startedAt }
        save(force: true)
        refreshMetrics()
        return added.count
    }

    func removeShifts(where test: (Shift) -> Bool) {
        history.removeAll(where: test)
        save(force: true)
        refreshMetrics()
    }

    private func load() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(Saved.self, from: data) else { return }
        current = saved.current
        history = saved.history
    }

    /// Saved at most every 30 s while miles accumulate, immediately on start/end/goal changes.
    private func save(force: Bool = false) {
        guard !PreviewData.isActive, let url = fileURL, force || Date().timeIntervalSince(lastSave) > 30 else { return }
        lastSave = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Saved(current: current, history: history)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Background GPS during a shift: adds up driven distance, ignoring poor fixes, GPS jumps, and standing-still jitter.
final class MileTracker: NSObject, CLLocationManagerDelegate {
    var onMove: ((CLLocation, CLLocationDistance) -> Void)?
    private let manager = CLLocationManager()
    private var last: CLLocation?
    private var lastMovedAt = Date()
    /// Parked for 3+ minutes: coarse GPS (battery) until the phone moves 150 m.
    private var saving = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        last = nil
        precise()
    }

    func idleCheck() {
        guard !saving, Date().timeIntervalSince(lastMovedAt) > 180 else { return }
        saving = true
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
    }

    private func precise() {
        saving = false
        lastMovedAt = Date()
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations where location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= (saving ? 120 : 50)
            && abs(location.timestamp.timeIntervalSinceNow) < 30 {
            if saving {
                // Coarse fixes only wake precise tracking; the miles are counted from the next precise fix.
                if let previous = last, location.distance(from: previous) > 150 { precise() }
                continue
            }
            guard let previous = last else { last = location; onMove?(location, 0); continue }
            let distance = location.distance(from: previous)
            let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
            guard seconds > 0 else { continue }
            if distance / seconds > 45 { last = location; onMove?(location, 0); continue } // A jump, not driving (> 100 mph).
            if distance < max(10, location.horizontalAccuracy) { onMove?(location, 0); continue } // Jitter while stopped.
            last = location
            lastMovedAt = Date()
            onMove?(location, distance)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
