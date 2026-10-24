import SwiftUI

/// Invented offers shown only when the app is launched with `-lumenPreview` (the cloud build's simulator
/// screenshots). Never used on the phone in normal launches.
enum PreviewData {
    static let isActive = ProcessInfo.processInfo.arguments.contains("-lumenPreview")
    /// The screen tour (UI test) forces dark mode, the user's phone setting.
    static var forcedScheme: ColorScheme? { ProcessInfo.processInfo.arguments.contains("-dark") ? .dark : nil }

    /// Which Home state the preview shows (user, Oct 21: "preview states of the app on my computer"): `waiting`, `offer`,
    /// `order`, or `orderOffer` (an offer arriving during an order). `-state <name>`; the screen tour's default is `order`.
    static var state: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-state"), i + 1 < args.count else { return "order" }
        return args[i + 1]
    }
    static var showsTrip: Bool { state == "order" || state == "orderOffer" || state == "orderNew" || state == "orderAtStore" }

    /// Just accepted (state `orderNew`): two stores and two drop-offs, nothing reached yet — the empty progress bar.
    static let newTrip: Trip = {
        let now = Date()
        return Trip(id: "trip-preview-new", startedAt: now.addingTimeInterval(-90), orders: [
            Trip.Order(offerId: "preview-new", platform: "doordash", payCents: 1520, merchant: "Potbelly", stores: ["Potbelly", "Cafe Zupas"],
                       dropoffs: 2, acceptedAt: now.addingTimeInterval(-90), ended: nil, endedAt: nil)
        ], steps: state == "orderAtStore"
            ? [Trip.Step(id: "pn1", kind: .arrivedStore, offerId: "preview-new", stop: 0, label: "Arrived at Potbelly", at: now.addingTimeInterval(-20))]
            : [], endedAt: nil)
    }()
    static var showsOffer: Bool { state == "offer" || state == "orderOffer" }

    static var initialTab: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-tab"), i + 1 < args.count else { return 0 }
        return Int(args[i + 1]) ?? 0
    }

    /// An invented map reading for the offer page's map check: store and drop-off pins, one unused pin, the dot, towns.
    static let mapCheckSample: [String: Any] = [
        "returnKind": "map", "returnMilliMiles": 6900, "uncertaintyMilliMiles": 800,
        "returnDebug": "pins 3, blue dot at phone position; labels Fairview/Greenville; towns matched 2; restaurant pin matched; map 4.1 mi wide",
        "mapSnapshot": #"{"pins":[{"centerX":0.36,"centerY":0.21,"radius":0.046,"kind":"store"},{"centerX":0.2,"centerY":0.46,"radius":0.046,"kind":"customer"},{"centerX":0.74,"centerY":0.30,"radius":0.03,"kind":"store"}],"labels":[{"text":"Greenville","x":0.25,"y":0.12},{"text":"Fairview","x":0.62,"y":0.40}],"dot":{"x":0.70,"y":0.35},"chosen":{"pickups":[{"x":0.36,"y":0.24}],"dropoffs":[{"x":0.2,"y":0.49}]}}"#
    ]

    /// Invented offers for the Breakdown screenshot: two weeks of afternoons and evenings across the three apps,
    /// mostly declines, more good ones at lunch and dinner (deterministic, so screenshots compare build to build).
    static let breakdownOffers: [LiveOffer] = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let apps = ["doordash", "uber_eats", "grubhub"]
        let stores = ["Chipotle", "Five Guys", "Panera Bread", "Raising Cane's", "Olive Garden", "Shake Shack", "Five Guys", "Cafe Zupas"]
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-14 * 86400)
        return (0..<160).compactMap { i in
            let day = next(14), hour = [11, 12, 12, 13, 17, 18, 18, 19, 20, 21][next(10)]
            let seen = start.addingTimeInterval(Double(day * 86400 + hour * 3600 + next(60) * 60))
            let miles = 2000 + next(12000), meal = hour == 12 || hour == 18
            let perMile = 45 + next(meal ? 110 : 80)
            let pay = miles * perMile / 1000
            let word = perMile >= 105 ? "Accept" : perMile >= 95 ? "Close call" : "Decline"
            let object: [String: Any] = ["seenAt": ISO8601DateFormatter().string(from: seen), "platform": apps[next(3)], "payCents": pay,
                                         "outboundMilliMiles": miles, "effectiveMilliMiles": miles, "merchant": stores[next(stores.count)],
                                         "confidence": 0.97, "tone": "good", "notice": String(format: "$%.2f/mi · ", Double(perMile) / 100) + word,
                                         "detail": "Sample", "headline": "Sample", "fingerprint": "b\(i)", "offerId": "preview-b\(i)"]
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? decoder.decode(LiveOffer.self, from: data)
        }
    }()

    /// An invented stacked trip for the screenshots: two DoorDash orders, first store done, waiting at the second.
    static let trip: Trip = {
        let now = Date()
        let started = now.addingTimeInterval(-19 * 60)
        return Trip(id: "trip-preview", startedAt: started, orders: [
            Trip.Order(offerId: "preview-a", platform: "doordash", payCents: 1060, merchant: "Five Guys", stores: ["Five Guys"],
                       dropoffs: 1, acceptedAt: started, ended: nil, endedAt: nil),
            Trip.Order(offerId: "preview-b", platform: "doordash", payCents: 875, merchant: "Chipotle", stores: ["Chipotle"],
                       dropoffs: 1, acceptedAt: now.addingTimeInterval(-11 * 60), ended: nil, endedAt: nil)
        ], steps: [
            Trip.Step(id: "p1", kind: .arrivedStore, offerId: "preview-a", stop: 0, label: "Arrived at Five Guys", at: now.addingTimeInterval(-13 * 60)),
            Trip.Step(id: "p2", kind: .leftStore, offerId: "preview-a", stop: 0, label: "Left Five Guys", at: now.addingTimeInterval(-8 * 60)),
            Trip.Step(id: "p3", kind: .arrivedStore, offerId: "preview-b", stop: 0, label: "Arrived at Chipotle", at: now.addingTimeInterval(-3 * 60))
        ], endedAt: nil)
    }()

    /// An invented running shift for the screenshots (2 h 10 min online, goal $150).
    static let shift = Shift(id: "shift-preview", startedAt: Date().addingTimeInterval(-130 * 60), endedAt: nil, pausedAt: nil,
                             meters: ["toPickup": 9_000, "delivery": 21_000, "driveBack": 6_500, "reposition": 3_000],
                             goalCents: 15_000, finalMetrics: nil)

    /// Finished invented trips: the Olive Garden offer completed, the Mendocino Farms one unassigned after a long wait.
    static let pastTrips: [Trip] = {
        let now = Date()
        let olive = now.addingTimeInterval(-590)
        let mendo = now.addingTimeInterval(-1090)
        return [
            Trip(id: "trip-preview-1", startedAt: mendo, orders: [
                Trip.Order(offerId: "preview-doordash-850", platform: "doordash", payCents: 850, merchant: "Mendocino Farms",
                           stores: ["Mendocino Farms"], dropoffs: 1, acceptedAt: mendo, ended: "unassigned", endedAt: mendo.addingTimeInterval(420))
            ], steps: [Trip.Step(id: "pp1", kind: .arrivedStore, offerId: "preview-doordash-850", stop: 0, label: "Arrived at Mendocino Farms",
                                 at: mendo.addingTimeInterval(120))], endedAt: mendo.addingTimeInterval(420)),
            Trip(id: "trip-preview-2", startedAt: olive, orders: [
                Trip.Order(offerId: "preview-uber_eats-2706", platform: "uber_eats", payCents: 2706, merchant: "Olive Garden",
                           stores: ["Olive Garden"], dropoffs: 2, acceptedAt: olive, ended: "completed", endedAt: olive.addingTimeInterval(-60 + 540))
            ], steps: [], endedAt: olive.addingTimeInterval(480))
        ]
    }()

    /// Earlier invented shifts this week (one and two days ago, 5–9 PM) with their orders, for the week chart.
    static let earlierDays: (shifts: [Shift], trips: [Trip]) = {
        let calendar = Calendar.current
        var shifts: [Shift] = [], trips: [Trip] = []
        for (daysAgo, pays) in [(1, [1240, 980, 1575, 860]), (2, [2210, 1130, 760])] {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date())),
                  let start = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day) else { continue }
            shifts.append(Shift(id: "shift-preview-\(daysAgo)", startedAt: start, endedAt: start.addingTimeInterval(4 * 3600), pausedAt: nil,
                                meters: ["toPickup": Double(pays.count) * 3_000, "delivery": Double(pays.count) * 6_500,
                                         "driveBack": 4_000, "reposition": Double(daysAgo) * 2_500],
                                goalCents: nil, finalMetrics: nil))
            for (index, pay) in pays.enumerated() {
                let accepted = start.addingTimeInterval(Double(index) * 3_300 + 600)
                trips.append(Trip(id: "trip-preview-\(daysAgo)-\(index)", startedAt: accepted, orders: [
                    Trip.Order(offerId: "preview-\(daysAgo)-\(index)", platform: ["doordash", "uber_eats", "grubhub"][index % 3], payCents: pay,
                               merchant: ["Five Guys", "Chipotle", "Panera Bread", "Culver's"][index % 4],
                               stores: [["Five Guys", "Chipotle", "Panera Bread", "Culver's"][index % 4]], dropoffs: 1,
                               acceptedAt: accepted, ended: "completed", endedAt: accepted.addingTimeInterval(Double(24 + index * 4) * 60))
                ], steps: [
                    Trip.Step(id: "pw\(daysAgo)\(index)a", kind: .arrivedStore, offerId: "preview-\(daysAgo)-\(index)", stop: 0, label: "", at: accepted.addingTimeInterval(420)),
                    Trip.Step(id: "pw\(daysAgo)\(index)b", kind: .leftStore, offerId: "preview-\(daysAgo)-\(index)", stop: 0, label: "", at: accepted.addingTimeInterval(420 + Double(4 + index * 3) * 60))
                ], endedAt: accepted.addingTimeInterval(Double(24 + index * 4) * 60)))
            }
        }
        return (shifts, trips)
    }()

    static let offers: [LiveOffer] = {
        let now = Date()
        let rows: [(String, Int, Int, String, String, String, Double, String)] = [
            ("grubhub", 876, 10200, "Roadtrip Bowls by Lazy Dog", "$0.85/mi · Decline", "bad", -1500, "Under $1/mi before the drive back"),
            ("doordash", 850, 3500, "Mendocino Farms", "≈$1.06/mi · Close call", "tight", -1100, "Return from map pin · ±0.8 mi"),
            ("uber_eats", 2706, 11900, "Olive Garden", "$1.31/mi · $27/hr · Accept", "good", -600, "Return from drop-off street"),
            ("uber_eats", 1384, 6700, "Five Guys", "$1.62/mi · $29/hr · Accept", "good", -12, "On your way home · saves 4.1 mi")
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return rows.compactMap { row in
            var object: [String: Any] = [
                "seenAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(row.6)),
                "platform": row.0, "payCents": row.1, "outboundMilliMiles": row.2, "merchant": row.3,
                "confidence": 0.97, "tone": row.5, "notice": row.4, "detail": "Sample offer (invented)",
                "headline": "Sample", "fingerprint": "\(row.0)|\(row.1)", "latencyFirstMs": 1400, "latencyRefinedMs": 5200,
                "offerId": "preview-\(row.0)-\(row.1)", "why": row.7
            ]
            if row.3 == "Mendocino Farms" { object.merge(mapCheckSample) { $1 } }
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? decoder.decode(LiveOffer.self, from: data)
        }
    }()
}
