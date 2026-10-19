import XCTest
import CoreLocation
@testable import Lumen

/// The trip state machine and arrival detection (review: the part most likely to quietly corrupt history).
final class TripTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func order(_ id: String, stores: [String], dropoffs: Int = 1) -> Trip.Order {
        Trip.Order(offerId: id, platform: "doordash", payCents: 1000, merchant: stores.first, stores: stores, dropoffs: dropoffs,
                   acceptedAt: t0, ended: nil, endedAt: nil)
    }
    private func step(_ kind: Trip.StepKind, _ id: String, _ stop: Int, _ minutes: Double, lat: Double? = nil, lon: Double? = nil) -> Trip.Step {
        var s = Trip.Step(id: "\(id)-\(kind)-\(stop)", kind: kind, offerId: id, stop: stop, label: "", at: t0.addingTimeInterval(minutes * 60))
        s.latitude = lat; s.longitude = lon
        return s
    }

    func testSingleOrderStepsInOrder() {
        var trip = Trip(id: "t", startedAt: t0, orders: [order("a", stores: ["Five Guys"])], steps: [], endedAt: nil)
        XCTAssertEqual(trip.actions.map(\.label), ["Arrived at Five Guys"])
        trip.steps.append(step(.arrivedStore, "a", 0, 5))
        XCTAssertEqual(trip.actions.map(\.label), ["Left Five Guys"])
        trip.steps.append(step(.leftStore, "a", 0, 12))
        XCTAssertEqual(trip.actions.map(\.label), ["Arrived at drop-off"])
        trip.steps.append(step(.arrivedDropoff, "a", 0, 25))
        XCTAssertEqual(trip.actions.map(\.label), ["Delivered · drop-off"])
    }

    func testTwoStoresMustBothBeLeftBeforeTheDropoff() {
        var trip = Trip(id: "t", startedAt: t0, orders: [order("a", stores: ["Cafe Zupas", "Crisp & Green"])], steps: [], endedAt: nil)
        XCTAssertEqual(Set(trip.actions.map(\.label)), ["Arrived at Cafe Zupas", "Arrived at Crisp & Green"])
        trip.steps += [step(.arrivedStore, "a", 0, 3), step(.leftStore, "a", 0, 6)]
        XCTAssertFalse(trip.actions.contains { $0.kind == .arrivedDropoff })
        trip.steps += [step(.arrivedStore, "a", 1, 9), step(.leftStore, "a", 1, 12)]
        XCTAssertEqual(trip.actions.first?.kind, .arrivedDropoff)
    }

    func testStackedOrdersAreIndependentAndLeavingComesFirst() {
        var trip = Trip(id: "t", startedAt: t0, orders: [order("a", stores: ["Five Guys"]), order("b", stores: ["Chipotle"])], steps: [], endedAt: nil)
        trip.steps += [step(.arrivedStore, "a", 0, 3), step(.leftStore, "a", 0, 8), step(.arrivedStore, "b", 0, 12)]
        XCTAssertEqual(trip.actions.first?.label, "Left Chipotle")
        XCTAssertTrue(trip.actions.contains { $0.kind == .arrivedDropoff && $0.offerId == "a" })
    }

    func testTwoDropoffsCountSeparately() {
        var trip = Trip(id: "t", startedAt: t0, orders: [order("a", stores: ["Olive Garden"], dropoffs: 2)], steps: [], endedAt: nil)
        trip.steps += [step(.arrivedStore, "a", 0, 3), step(.leftStore, "a", 0, 8), step(.arrivedDropoff, "a", 0, 15), step(.delivered, "a", 0, 17)]
        XCTAssertEqual(trip.actions.first?.label, "Arrived at drop-off 2 of 2")
    }

    func testPaceIncludesThePredictedDriveBack() {
        var o = order("a", stores: ["X"])
        o.ended = "completed"; o.endedAt = t0.addingTimeInterval(20 * 60); o.payCents = 1500; o.predictedReturnMinutes = 10
        XCTAssertEqual(o.paceCents, 4500)
        XCTAssertEqual(o.paceWithReturnCents, 3000)
    }

    func testStoreNamesAndHourlyFromNotice() {
        XCTAssertEqual(TripOfferInfo.storeNames(["Cafe Zupas"], nil, 2), ["Cafe Zupas", "Store 2"])
        XCTAssertEqual(TripOfferInfo.storeNames(nil, "Chipotle", nil), ["Chipotle"])
        XCTAssertEqual(TripOfferInfo.hourly(from: "$1.16/mi · $27/hr · Accept"), 2700)
        XCTAssertNil(TripOfferInfo.hourly(from: "Check offer"))
    }

    // MARK: Arrival detection

    private let store = CLLocation(latitude: 39.8400, longitude: -98.5400)
    private func at(_ lat: Double, _ lon: Double, seconds: Double, speed: Double = 0) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 0, horizontalAccuracy: 10,
                   verticalAccuracy: 10, course: -1, speed: speed, timestamp: t0.addingTimeInterval(seconds))
    }

    func testArrivesAtAStoreOnlyAfterTwentySecondsNearby() {
        var detector = ArrivalDetector()
        let trip = Trip(id: "t", startedAt: t0, orders: [order("a", stores: ["Five Guys"])], steps: [], endedAt: nil)
        let spots = [TripAction(kind: .arrivedStore, offerId: "a", stop: 0, label: "").id: store]
        XCTAssertNil(detector.next(at: at(39.8401, -98.5400, seconds: 0), trip: trip, storeSpots: spots))
        XCTAssertNil(detector.next(at: at(39.8401, -98.5401, seconds: 10), trip: trip, storeSpots: spots))
        XCTAssertEqual(detector.next(at: at(39.8401, -98.5401, seconds: 25), trip: trip, storeSpots: spots)?.kind, .arrivedStore)
    }

    func testPassingByDoesNotCount() {
        var detector = ArrivalDetector()
        let trip = Trip(id: "t", startedAt: t0, orders: [order("a", stores: ["Five Guys"])], steps: [], endedAt: nil)
        let spots = [TripAction(kind: .arrivedStore, offerId: "a", stop: 0, label: "").id: store]
        XCTAssertNil(detector.next(at: at(39.8401, -98.5400, seconds: 0, speed: 12), trip: trip, storeSpots: spots))
        XCTAssertNil(detector.next(at: at(39.8430, -98.5400, seconds: 15, speed: 12), trip: trip, storeSpots: spots))
        XCTAssertNil(detector.next(at: at(39.8470, -98.5400, seconds: 30, speed: 12), trip: trip, storeSpots: spots))
    }

    func testLeavesTheStoreThenStopsAtTheDropoffThenDelivers() {
        var detector = ArrivalDetector()
        var trip = Trip(id: "t", startedAt: t0, orders: [order("a", stores: ["Five Guys"])], steps: [], endedAt: nil)
        trip.steps.append(step(.arrivedStore, "a", 0, 0, lat: 39.8400, lon: -98.5400))
        XCTAssertEqual(detector.next(at: at(39.8430, -98.5400, seconds: 300, speed: 10), trip: trip, storeSpots: [:])?.kind, .leftStore)
        trip.steps.append(step(.leftStore, "a", 0, 5))
        // Parked about 2 km away: not yet at 90 seconds, the drop-off at 160.
        XCTAssertNil(detector.next(at: at(39.8580, -98.5400, seconds: 900), trip: trip, storeSpots: [:]))
        XCTAssertNil(detector.next(at: at(39.8580, -98.5401, seconds: 990), trip: trip, storeSpots: [:]))
        XCTAssertEqual(detector.next(at: at(39.8580, -98.5401, seconds: 1060), trip: trip, storeSpots: [:])?.kind, .arrivedDropoff)
        trip.steps.append(step(.arrivedDropoff, "a", 0, 17.7))
        XCTAssertNil(detector.next(at: at(39.8581, -98.5401, seconds: 1100), trip: trip, storeSpots: [:]))
        XCTAssertEqual(detector.next(at: at(39.8600, -98.5400, seconds: 1150, speed: 8), trip: trip, storeSpots: [:])?.kind, .delivered)
    }

    func testARedLightAfterTheStoreIsNotTheDropoff() {
        // Field bug (Oct 16): stopped at a light ~1 km out right after leaving, then "delivered" on driving away.
        var detector = ArrivalDetector()
        var trip = Trip(id: "t", startedAt: t0, orders: [order("a", stores: ["Five Guys"])], steps: [], endedAt: nil)
        trip.steps.append(step(.arrivedStore, "a", 0, 0, lat: 39.8400, lon: -98.5400))
        trip.steps.append(step(.leftStore, "a", 0, 5))
        XCTAssertNil(detector.next(at: at(39.8490, -98.5400, seconds: 360), trip: trip, storeSpots: [:]))
        XCTAssertNil(detector.next(at: at(39.8490, -98.5401, seconds: 540), trip: trip, storeSpots: [:]))
        XCTAssertNil(detector.next(at: at(39.8530, -98.5400, seconds: 560, speed: 12), trip: trip, storeSpots: [:]))
    }

    func testWhileReadingDrivingAwayFromAScreenConfirmedDropoffDelivers() {
        var detector = ArrivalDetector()
        var trip = Trip(id: "t", startedAt: t0, orders: [order("a", stores: ["Five Guys"])], steps: [], endedAt: nil)
        trip.steps.append(step(.arrivedStore, "a", 0, 0, lat: 39.8400, lon: -98.5400))
        trip.steps.append(step(.leftStore, "a", 0, 5))
        trip.steps.append(step(.arrivedDropoff, "a", 0, 15))   // From the app's "at the customer" screen.
        XCTAssertNil(detector.next(at: at(39.8580, -98.5400, seconds: 910), trip: trip, storeSpots: [:], dropoffs: false))
        // Walking 120 m to the door and back: not delivered.
        XCTAssertNil(detector.next(at: at(39.8591, -98.5400, seconds: 960, speed: 1.4), trip: trip, storeSpots: [:], dropoffs: false))
        // Driving away: delivered.
        XCTAssertEqual(detector.next(at: at(39.8610, -98.5400, seconds: 1100, speed: 9), trip: trip, storeSpots: [:], dropoffs: false)?.kind, .delivered)
    }

    func testNoDropoffFromGPSWhileTheScreenIsRead() {
        var detector = ArrivalDetector()
        var trip = Trip(id: "t", startedAt: t0, orders: [order("a", stores: ["Five Guys"])], steps: [], endedAt: nil)
        trip.steps.append(step(.arrivedStore, "a", 0, 0, lat: 39.8400, lon: -98.5400))
        trip.steps.append(step(.leftStore, "a", 0, 5))
        XCTAssertNil(detector.next(at: at(39.8580, -98.5400, seconds: 900), trip: trip, storeSpots: [:], dropoffs: false))
        XCTAssertNil(detector.next(at: at(39.8580, -98.5401, seconds: 1200), trip: trip, storeSpots: [:], dropoffs: false))
    }

    func testAnUndoneStepIsNotRepeatedRightAway() {
        var detector = ArrivalDetector()
        var trip = Trip(id: "t", startedAt: t0, orders: [order("a", stores: ["Five Guys"])], steps: [], endedAt: nil)
        trip.steps.append(step(.arrivedStore, "a", 0, 0, lat: 39.8400, lon: -98.5400))
        XCTAssertEqual(detector.next(at: at(39.8430, -98.5400, seconds: 60, speed: 10), trip: trip, storeSpots: [:])?.kind, .leftStore)
        // The driver undid it (still away from the store): no repeat within 10 minutes.
        XCTAssertNil(detector.next(at: at(39.8435, -98.5400, seconds: 120, speed: 10), trip: trip, storeSpots: [:]))
    }

    // Rule 2 of LifecycleSync: a pickup screen accepts only the offer from its store (Oct 18 shift).
    func testPickupScreenStoreCodeMatchesOnlyItsOffer() {
        let screen = LifecycleSignal.storeCode("Chipotle (375 N Milwaukee)")!
        XCTAssertTrue(LifecycleSignal.storeCodes(["Chipotle Mexican Grill (375 N Milwauke"]).contains(screen))
        XCTAssertFalse(LifecycleSignal.storeCodes(["Pizzeria Deville"]).contains(screen))
        XCTAssertEqual(LifecycleSignal(name: LifecycleSignal(platform: "uber_eats", state: "at_store", store: screen).name)?.store, screen)
        XCTAssertNil(LifecycleSignal.storeCode("The Grill"))
    }
}
