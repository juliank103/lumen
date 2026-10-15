import Foundation

/// Four weeks of invented shifts, offers, and trips (user, Oct 15) so the app has something to show after a fresh
/// install. Everything has a "demo-" id: it is left out of exports and the journal, and "Remove demo data" deletes it.
/// Today is left empty for the real shift. Same seed → same data every time.
enum DemoData {
    static let prefix = "demo-"
    static func isDemo(_ id: String?) -> Bool { id?.hasPrefix(prefix) ?? false }

    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func between(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
        mutating func pick<T>(_ items: [T]) -> T { items[min(items.count - 1, Int(next() * Double(items.count)))] }
    }

    private static let stores = ["Five Guys", "Chipotle", "Panera Bread", "Culver's", "Chick-fil-A", "Starbucks", "Jimmy John's",
                                 "Olive Garden", "Buffalo Wild Wings", "Taco Bell", "McDonald's", "Wingstop", "Cafe Zupas", "Potbelly"]
    private static let areas = ["Fairview", "Riverside", "Greenville", "Franklin", "Clinton", "Madison", "Springfield"]
    // Some stores are slow (the wait learning has something to find).
    private static let slow: Set<String> = ["Wingstop", "Olive Garden", "Buffalo Wild Wings"]

    static func make(now: Date = Date()) -> (offers: [LiveOffer], trips: [Trip], shifts: [Shift]) {
        var rng = Random(state: 2026_10_15)
        let calendar = Calendar.current
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let iso = ISO8601DateFormatter()
        var offers: [LiveOffer] = [], trips: [Trip] = [], shifts: [Shift] = []
        var serial = 0

        for daysAgo in stride(from: 27, through: 1, by: -1) {
            guard rng.next() > 0.3, let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) else { continue }
            let lunch = rng.next() < 0.45
            let start = day.addingTimeInterval((lunch ? 10.75 : 16.25) * 3600 + rng.between(0, 2700))
            let plannedEnd = start.addingTimeInterval(rng.between(3.5, 6) * 3600)
            var meters: [String: Double] = [:], buckets: [String: [String: Double]] = [:]
            func addMiles(_ kind: String, _ miles: Double, at time: Date) {
                let m = miles * 1609.344
                meters[kind, default: 0] += m
                buckets[String(Int(time.timeIntervalSince1970 / 3600) * 3600), default: [:]][kind, default: 0] += m
            }
            addMiles("reposition", rng.between(0.5, 4), at: start.addingTimeInterval(300))
            var t = start.addingTimeInterval(rng.between(240, 900))
            while t < plannedEnd.addingTimeInterval(-1200) {
                serial += 1
                let platform = rng.pick(["doordash", "doordash", "uber_eats", "uber_eats", "grubhub"])
                let store = rng.pick(stores)
                let miles = rng.between(1.4, 11)
                let pay = max(3.5, miles * rng.between(0.75, 2.1) + rng.between(0, 4))
                let returnMiles = rng.between(0.3, 5)
                let perMile = pay / max(0.5, miles + returnMiles * 0.6)
                let appMinutes = Int((miles * 2.6 + rng.between(6, 14)).rounded())
                let hourly = Int(pay * 60 / Double(appMinutes + 8))
                let accept = perMile >= 1.0 && hourly >= 25 && rng.next() < 0.85
                let close = !accept && perMile >= 0.95
                let notice = close ? String(format: "≈$%.2f/mi · Close call", perMile)
                    : String(format: "$%.2f/mi · $%d/hr · %@", perMile, hourly, accept ? "Accept" : "Decline")
                let offerId = prefix + "offer-\(serial)"
                var object: [String: Any] = [
                    "seenAt": iso.string(from: t), "platform": platform, "payCents": Int((pay * 100).rounded()),
                    "outboundMilliMiles": Int((miles * 1000).rounded()), "appMinutes": appMinutes, "merchant": store,
                    "merchants": [store], "pickupCount": 1, "dropoffCount": 1, "orderCount": 1, "confidence": 0.96,
                    "tone": accept ? "good" : close ? "tight" : "bad", "notice": notice, "detail": "Demo offer (invented)",
                    "headline": "Demo", "fingerprint": "demo|\(serial)", "offerId": offerId,
                    "returnMilliMiles": Int((returnMiles * 1000).rounded()), "returnKind": "map",
                    "hourlyCents": hourly * 100, "tripMinutes": appMinutes, "returnMinutes": 8,
                    "latencyFirstMs": Int(rng.between(700, 1900)), "latencyRefinedMs": Int(rng.between(2500, 6500))
                ]
                if platform == "uber_eats" { object["dropoffArea"] = rng.pick(areas) }
                if let data = try? JSONSerialization.data(withJSONObject: object), let offer = try? decoder.decode(LiveOffer.self, from: data) {
                    offers.append(offer)
                }
                guard accept else { t = t.addingTimeInterval(rng.between(180, 720)); continue }

                // An accepted trip, sometimes with a stacked second order from the same app.
                let tripId = prefix + "trip-\(serial)"
                let accepted = t.addingTimeInterval(rng.between(8, 30))
                var orders: [Trip.Order] = [], steps: [Trip.Step] = []
                var clock = accepted
                let toStore = rng.between(4, 12) * 60
                addMiles("toPickup", miles * 0.3, at: accepted)
                clock += toStore
                let slowStore = slow.contains(store)
                let wait = (slowStore ? rng.between(8, 22) : rng.between(2, 10)) * 60
                let unassign = slowStore && wait > 19 * 60
                steps.append(Trip.Step(id: tripId + "-a1", kind: .arrivedStore, offerId: offerId, stop: 0, label: "Arrived at \(store)", at: clock))
                if unassign {
                    let end = clock + wait
                    orders.append(Trip.Order(offerId: offerId, platform: platform, payCents: Int((pay * 100).rounded()), merchant: store, stores: [store],
                                             dropoffs: 1, acceptedAt: accepted, ended: "unassigned", endedAt: end))
                    trips.append(Trip(id: tripId, startedAt: accepted, orders: orders, steps: steps, endedAt: end))
                    addMiles("reposition", rng.between(0.5, 2), at: end)
                    t = end.addingTimeInterval(rng.between(120, 600))
                    continue
                }
                clock += wait
                steps.append(Trip.Step(id: tripId + "-l1", kind: .leftStore, offerId: offerId, stop: 0, label: "Left \(store)", at: clock))
                var stacked: (id: String, store: String, pay: Double)?
                if rng.next() < 0.15 {
                    serial += 1
                    let second = rng.pick(stores.filter { $0 != store })
                    let secondPay = rng.between(4, 11)
                    let secondId = prefix + "offer-\(serial)"
                    stacked = (secondId, second, secondPay)
                    let addedAt = clock.addingTimeInterval(-rng.between(60, 240))
                    let secondObject: [String: Any] = [
                        "seenAt": iso.string(from: addedAt.addingTimeInterval(-20)), "platform": platform, "payCents": Int((secondPay * 100).rounded()),
                        "outboundMilliMiles": 2800, "merchant": second, "merchants": [second], "pickupCount": 1, "dropoffCount": 1,
                        "confidence": 0.95, "tone": "good", "notice": "$1.32/mi · $31/hr · Accept", "detail": "Demo add-on (invented)",
                        "headline": "Demo", "fingerprint": "demo|\(serial)", "offerId": secondId]
                    if let data = try? JSONSerialization.data(withJSONObject: secondObject), let offer = try? decoder.decode(LiveOffer.self, from: data) {
                        offers.append(offer)
                    }
                    clock += rng.between(3, 7) * 60
                    steps.append(Trip.Step(id: tripId + "-a2", kind: .arrivedStore, offerId: secondId, stop: 0, label: "Arrived at \(second)", at: clock))
                    clock += rng.between(2, 8) * 60
                    steps.append(Trip.Step(id: tripId + "-l2", kind: .leftStore, offerId: secondId, stop: 0, label: "Left \(second)", at: clock))
                }
                let drive = miles * 0.7 * rng.between(1.9, 2.6) * 60
                clock += drive
                addMiles("delivery", miles * 0.7, at: clock)
                steps.append(Trip.Step(id: tripId + "-d1", kind: .arrivedDropoff, offerId: offerId, stop: 0, label: "Arrived at drop-off", at: clock))
                clock += rng.between(1, 4) * 60
                steps.append(Trip.Step(id: tripId + "-x1", kind: .delivered, offerId: offerId, stop: 0, label: "Delivered", at: clock))
                orders.append(Trip.Order(offerId: offerId, platform: platform, payCents: Int((pay * 100).rounded()), merchant: store, stores: [store],
                                         dropoffs: 1, acceptedAt: accepted, ended: "completed", endedAt: clock,
                                         predictedHourlyCents: hourly * 100, predictedTripMinutes: appMinutes, predictedReturnMinutes: 8))
                if let stacked {
                    clock += rng.between(4, 9) * 60
                    addMiles("delivery", 2.8, at: clock)
                    steps.append(Trip.Step(id: tripId + "-d2", kind: .arrivedDropoff, offerId: stacked.id, stop: 0, label: "Arrived at drop-off", at: clock))
                    clock += rng.between(1, 3) * 60
                    steps.append(Trip.Step(id: tripId + "-x2", kind: .delivered, offerId: stacked.id, stop: 0, label: "Delivered", at: clock))
                    orders.append(Trip.Order(offerId: stacked.id, platform: platform, payCents: Int((stacked.pay * 100).rounded()), merchant: stacked.store,
                                             stores: [stacked.store], dropoffs: 1, acceptedAt: accepted.addingTimeInterval(toStore + wait - 120),
                                             ended: "completed", endedAt: clock))
                }
                trips.append(Trip(id: tripId, startedAt: accepted, orders: orders, steps: steps, endedAt: clock))
                addMiles("driveBack", returnMiles * rng.between(0.4, 1), at: clock.addingTimeInterval(300))
                t = clock.addingTimeInterval(rng.between(240, 1100))
            }
            shifts.append(Shift(id: prefix + "shift-\(daysAgo)", startedAt: start, endedAt: max(plannedEnd, t), pausedAt: nil,
                                meters: meters, goalCents: 15_000, finalMetrics: nil, buckets: buckets))
        }
        return (offers, trips, shifts)
    }
}
