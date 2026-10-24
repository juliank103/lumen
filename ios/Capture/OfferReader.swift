import Foundation
import JavaScriptCore

// Runs the shared reader (core/screen-reader.js + core/copilot.js) on one frame's OCR lines.
// The same JavaScript is tested on Windows against real offer-card screenshots. Use from one queue only.
final class OfferReader {
    struct Line { let text: String; let x: Double; let y: Double; let w: Double; let h: Double }

    /// One recognized card before the return is added. `json` still holds the transient routing queries.
    struct Summary {
        let json: String
        let fingerprint: String
        let platform: String
        let confidence: Double
        let outboundMilliMiles: Int?
        let dropoffQuery: String?
        let pickupQuery: String?
        let pickupCount: Int
        let mapBottom: Double
        /// DoorDash "Deliver by" without minutes: read the status-bar clock and summarize again.
        let needsClock: Bool
        /// The card's own time to the last drop-off, if shown.
        let appMinutes: Int?
        /// Notification title ("Uber Eats $13.84 · 6.7 mi").
        let headline: String
        /// First restaurant's name (searched near the driver when the card has no address) and the drop-off count.
        let pickupName: String?
        let dropoffCount: Int
    }

    /// Pins and town labels found on the offer map (core/map-reader.js), before any lookups.
    struct MapAnalysis {
        let json: String
        let labels: [String]
        /// Pins found (0 usually means the map hadn't loaded or was mid-zoom).
        var pins: Int = 0
    }

    /// Drop-off coordinates read off the map, with the position uncertainty in miles; or why there are none.
    struct MapLocation {
        let dropoffs: [(latitude: Double, longitude: Double)]
        /// The driver's dot on the map, if shown.
        let current: (Double, Double)?
        /// Pickup pins on the map, for timing the trip.
        let pickups: [(Double, Double)]
        let uncertaintyMiles: Double
        let reason: String?
        /// Pin/label counts and town names, for the offer list. Never customer details.
        let debug: String?
        /// The pins taken as pickup(s) and drop-off(s), as screen positions (JSON), for the offer's map check.
        var screenJSON: String? = nil
    }

    private let context: JSContext
    private let summarizeFunction: JSValue
    private let withReturnFunction: JSValue
    private let analyzeMapFunction: JSValue
    private let analyzeDetectedFunction: JSValue?
    private let locateFunction: JSValue
    private let preliminaryFunction: JSValue
    private let shouldUpdateFunction: JSValue
    private let statusFunction: JSValue
    private let journalFunction: JSValue
    private var failure: String?

    init?() {
        let bundle = Bundle(for: OfferReader.self)
        guard let context = JSContext(),
              let engineURL = bundle.url(forResource: "copilot", withExtension: "js"),
              let readerURL = bundle.url(forResource: "screen-reader", withExtension: "js"),
              let mapURL = bundle.url(forResource: "map-reader", withExtension: "js"),
              let lifecycleURL = bundle.url(forResource: "lifecycle", withExtension: "js"),
              let engine = try? String(contentsOf: engineURL, encoding: .utf8),
              let reader = try? String(contentsOf: readerURL, encoding: .utf8),
              let map = try? String(contentsOf: mapURL, encoding: .utf8),
              let lifecycle = try? String(contentsOf: lifecycleURL, encoding: .utf8) else { return nil }
        self.context = context
        var loadError: String?
        context.exceptionHandler = { _, exception in loadError = exception?.toString() ?? "Reader failed" }
        context.evaluateScript(engine)
        context.evaluateScript(reader)
        context.evaluateScript(map)
        context.evaluateScript(lifecycle)
        guard loadError == nil,
              let api = context.objectForKeyedSubscript("ScreenReader"),
              let summarize = api.objectForKeyedSubscript("summarizeJSON"), !summarize.isUndefined,
              let withReturn = api.objectForKeyedSubscript("withReturnJSON"), !withReturn.isUndefined,
              let preliminary = api.objectForKeyedSubscript("preliminaryJSON"), !preliminary.isUndefined,
              let shouldUpdate = api.objectForKeyedSubscript("shouldUpdate"), !shouldUpdate.isUndefined,
              let status = api.objectForKeyedSubscript("readStatusJSON"), !status.isUndefined,
              let mapAPI = context.objectForKeyedSubscript("MapReader"),
              let analyze = mapAPI.objectForKeyedSubscript("analyzeJSON"), !analyze.isUndefined,
              let locate = mapAPI.objectForKeyedSubscript("locateJSON"), !locate.isUndefined,
              let lifecycleAPI = context.objectForKeyedSubscript("Lifecycle"),
              let journal = lifecycleAPI.objectForKeyedSubscript("offerEventsJSON"), !journal.isUndefined else { return nil }
        summarizeFunction = summarize
        withReturnFunction = withReturn
        analyzeMapFunction = analyze
        let detected = mapAPI.objectForKeyedSubscript("analyzeDetectedJSON")
        analyzeDetectedFunction = detected?.isUndefined == false ? detected : nil
        locateFunction = locate
        preliminaryFunction = preliminary
        shouldUpdateFunction = shouldUpdate
        statusFunction = status
        journalFunction = journal
        context.exceptionHandler = { [weak self] _, exception in self?.failure = exception?.toString() ?? "Reader failed" }
    }

    /// Stage 1 verdict from the card and a recent drive-back measurement (nil = position unknown).
    func preliminary(_ summary: Summary, credit: (milliMiles: Int, minutes: Int)?) throws -> (word: String, notice: String) {
        var context: [String: Any] = [:]
        if let credit { context["creditMilliMiles"] = credit.milliMiles; context["creditMinutes"] = credit.minutes }
        let contextJSON = String(data: try JSONSerialization.data(withJSONObject: context), encoding: .utf8) ?? "{}"
        guard let text = try call(preliminaryFunction, [summary.json, contextJSON, Self.settingsJSON]), let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let word = object["word"] as? String, let notice = object["notice"] as? String else { return ("Unreadable", "Check offer") }
        return (word, notice)
    }

    /// The order state the screen shows (app + state, e.g. DoorDash "at_store"), or nil. No customer details.
    /// `tolerant`: matched despite OCR mistakes (not word for word) — acted on only after a second matching read.
    /// `store`: the store name a pickup screen shows (a business, never a customer), or nil.
    func status(_ lines: [Line]) -> (platform: String, state: String, tolerant: Bool, store: String?)? {
        let payload = lines.map { ["text": $0.text, "x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] as [String: Any] }
        guard let json = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: json, encoding: .utf8),
              let output = try? call(statusFunction, [text]), let data = output.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let platform = object["platform"] as? String, let state = object["state"] as? String else { return nil }
        return (platform, state, object["tolerant"] as? Bool ?? false, object["store"] as? String)
    }

    /// Whether the refined notice changes the stage-1 recommendation enough to notify again.
    func shouldUpdate(preliminaryWord: String, refinedNotice: String) -> Bool {
        failure = nil
        let result = shouldUpdateFunction.call(withArguments: [preliminaryWord, refinedNotice])
        return failure == nil && (result?.toBool() ?? false)
    }

    /// pixels: RGBA bytes of the map region; lines: OCR of that region in full-screen coordinates.
    /// detections: the pin model's typed pins (JSON) — used instead of the pixel pin finder when given.
    func analyzeMap(pixels: Data, width: Int, height: Int, platform: String, top: Double, bottom: Double,
                    aspect: Double, lines: [Line], detections: String? = nil) throws -> MapAnalysis? {
        let payload = lines.map { ["text": $0.text, "x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] as [String: Any] }
        guard let linesJSON = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) else { return nil }
        let region = "{\"top\":\(top),\"height\":\(bottom - top)}"
        let arguments: [Any] = detections != nil && analyzeDetectedFunction != nil
            ? [detections!, pixels.base64EncodedString(), width, height, platform, region, aspect, linesJSON]
            : [pixels.base64EncodedString(), width, height, platform, region, aspect, linesJSON]
        guard let text = try call(detections != nil ? analyzeDetectedFunction ?? analyzeMapFunction : analyzeMapFunction, arguments),
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let labels = (object["labels"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let pins = ((object["found"] as? [String: Any])?["pins"] as? [Any])?.count ?? 0
        return MapAnalysis(json: text, labels: labels, pins: pins)
    }

    /// places: matched town labels as [text: (lat, lon)]; pickup: the restaurant's coordinate if its address was found.
    /// phone: the phone's own position (anchors the driver dot); dropoffCount/outbound from the card.
    func locate(_ analysis: MapAnalysis, places: [String: (Double, Double)], pickup: (Double, Double)?,
                platform: String, pickupCount: Int, phone: (lat: Double, lon: Double)?, dropoffCount: Int,
                outboundMilliMiles: Int?) throws -> MapLocation {
        let placeList = places.map { ["text": $0.key, "lat": $0.value.0, "lon": $0.value.1] as [String: Any] }
        let placesJSON = String(data: try JSONSerialization.data(withJSONObject: placeList), encoding: .utf8) ?? "[]"
        let pickupJSON: Any = pickup.map { "{\"lat\":\($0.0),\"lon\":\($0.1)}" } ?? NSNull()
        var extra: [String: Any] = ["dropoffCount": dropoffCount]
        if let phone { extra["current"] = ["lat": phone.lat, "lon": phone.lon] }
        if let outboundMilliMiles { extra["outboundMilliMiles"] = outboundMilliMiles }
        let extraJSON = String(data: try JSONSerialization.data(withJSONObject: extra), encoding: .utf8) ?? "{}"
        guard let text = try call(locateFunction, [analysis.json, placesJSON, platform, pickupCount, pickupJSON, extraJSON]),
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MapLocation(dropoffs: [], current: nil, pickups: [], uncertaintyMiles: 0, reason: "Map could not be read", debug: nil)
        }
        let pickups = (object["pickups"] as? [[String: Any]] ?? []).compactMap { item -> (Double, Double)? in
            guard let lat = item["lat"] as? Double, let lon = item["lon"] as? Double else { return nil }
            return (lat, lon)
        }
        let currentObject = object["current"] as? [String: Any]
        let current = (currentObject?["lat"] as? Double).flatMap { lat in (currentObject?["lon"] as? Double).map { (lat, $0) } }
        let dropoffs = (object["dropoffs"] as? [[String: Any]] ?? []).compactMap { item -> (latitude: Double, longitude: Double)? in
            guard let lat = item["lat"] as? Double, let lon = item["lon"] as? Double else { return nil }
            return (lat, lon)
        }
        let screen = (object["screen"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) }
        return MapLocation(dropoffs: dropoffs, current: current, pickups: pickups, uncertaintyMiles: object["uncertaintyMiles"] as? Double ?? 1,
                           reason: object["reason"] as? String, debug: object["debug"] as? String, screenJSON: screen)
    }

    /// The user's rules (default $1 per total mile and $25/hour gross), edited in the app (Account) and read from the
    /// App Group for every offer.
    /// The rules plus trip-time corrections learned from your orders (TimingStore, Oct 23).
    static var settingsJSON: String { TimingStore.settingsJSON(RulesStore.current) }

    /// Returns nil when the screen is not a recognized offer card. Throws only if the reader itself fails.
    /// clockText: the status-bar clock as read on screen ("5:11"); preferred over the phone clock for "Deliver by".
    func summarize(_ lines: [Line], at date: Date, clockText: String? = nil) throws -> Summary? {
        let payload = lines.map { ["text": $0.text, "x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] as [String: Any] }
        guard let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) else { return nil }
        // Minutes since local midnight, for DoorDash's "Deliver by" time.
        let clock = Calendar.current.dateComponents([.hour, .minute], from: date)
        var optionObject: [String: Any] = ["localMinutes": (clock.hour ?? 0) * 60 + (clock.minute ?? 0)]
        if let clockText { optionObject["clockText"] = clockText }
        let options = String(data: try JSONSerialization.data(withJSONObject: optionObject), encoding: .utf8) ?? "{}"
        guard let text = try call(summarizeFunction, [json, Self.settingsJSON, options]), text != "null", let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fingerprint = object["fingerprint"] as? String else { return nil }
        let routing = object["routing"] as? [String: Any]
        return Summary(json: text, fingerprint: fingerprint, platform: object["platform"] as? String ?? "",
                       confidence: object["confidence"] as? Double ?? 0,
                       outboundMilliMiles: object["outboundMilliMiles"] as? Int,
                       dropoffQuery: routing?["dropoffQuery"] as? String, pickupQuery: routing?["pickupQuery"] as? String,
                       pickupCount: routing?["pickupCount"] as? Int ?? 1, mapBottom: routing?["mapBottom"] as? Double ?? 0.5,
                       needsClock: object["needsClock"] as? Bool ?? false, appMinutes: object["appMinutes"] as? Int,
                       headline: object["headline"] as? String ?? "Offer",
                       pickupName: routing?["pickupName"] as? String, dropoffCount: routing?["dropoffCount"] as? Int ?? 1)
    }

    /// Journal events for one offer (core/lifecycle.js): what the card showed, kept apart from both predictions and
    /// the logic versions that made them (addendum §8–10). Empty if the script fails; the caller then keeps the old record.
    func journalEvents(_ input: [String: Any]) -> [[String: Any]] {
        guard JSONSerialization.isValidJSONObject(input), let data = try? JSONSerialization.data(withJSONObject: input),
              let inputJSON = String(data: data, encoding: .utf8), let text = try? call(journalFunction, [inputJSON]),
              let output = text.data(using: .utf8),
              let events = (try? JSONSerialization.jsonObject(with: output)) as? [[String: Any]] else { return [] }
        return events
    }

    /// Adds the return (if any), strips the routing queries, and produces the stored/notified offer, plus the full refined
    /// result for the journal (it has predicted fields the offer list does not show).
    /// credit: the drive from here back to __HOME_NAME__, which the user makes anyway; charged to the previous order.
    func finalize(_ summary: Summary, route: ReturnRouter.Route?, credit: ReturnRouter.Leg?, note: String?, debug: String?,
                  at date: Date, extra: [String: Any] = [:]) throws -> (offer: LiveOffer, object: [String: Any])? {
        var routeObject: [String: Any] = [:]
        if let debug { routeObject["debug"] = debug }
        if let route {
            routeObject["kind"] = route.kind
            routeObject["returnMilliMiles"] = route.milliMiles
            if let uncertainty = route.uncertaintyMilliMiles { routeObject["uncertaintyMilliMiles"] = uncertainty }
            if let minutes = route.returnMinutes { routeObject["returnMinutes"] = minutes }
            if let minutes = route.tripDriveMinutes { routeObject["tripDriveMinutes"] = minutes }
        }
        if let credit {
            routeObject["creditMilliMiles"] = ReturnRouter.milliMiles(credit.meters)
            routeObject["creditMinutes"] = ReturnRouter.minutes(credit.seconds)
        }
        if let note { routeObject["note"] = note }
        let routeJSON = String(data: try JSONSerialization.data(withJSONObject: routeObject), encoding: .utf8) ?? "null"
        guard let text = try call(withReturnFunction, [summary.json, routeJSON, Self.settingsJSON]), let data = text.data(using: .utf8),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object["seenAt"] = ISO8601DateFormatter().string(from: date)
        for (key, value) in extra { object[key] = value }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try decoder.decode(LiveOffer.self, from: JSONSerialization.data(withJSONObject: object)), object)
    }

    private func call(_ function: JSValue, _ arguments: [Any]) throws -> String? {
        failure = nil
        let output = function.call(withArguments: arguments)
        if let failure { throw NSError(domain: "Lumen", code: 2, userInfo: [NSLocalizedDescriptionKey: failure]) }
        return output?.toString()
    }
}
