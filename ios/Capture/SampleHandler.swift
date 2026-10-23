import ReplayKit
import Vision
import CoreImage
import ImageIO
import UserNotifications

final class SampleHandler: RPBroadcastSampleHandler {
    // Offer cards in the user's screenshots start at 47–55% of screen height.
    private static let readFraction: CGFloat = 0.6
    // Change detection (roadmap §4): a 24-px-wide grayscale thumbnail of the card area every 0.25 s. A large change
    // (an offer card sliding in) triggers OCR at once instead of waiting for the 2-second baseline.
    private static let senseInterval: TimeInterval = 0.25, changeThreshold = 10.0, minChangeOCRInterval: TimeInterval = 0.7
    private let processing = DispatchQueue(label: "copilot.capture.probe", qos: .utility)
    private let sensingQueue = DispatchQueue(label: "copilot.capture.sense", qos: .utility)
    private let gate = NSLock()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    // Guarded by `gate`.
    private var busy = false
    private var active = false
    private var lastScheduled = Date.distantPast
    private var sensing = false
    private var lastSensed = Date.distantPast
    private var changePending = false
    private var lastThumbnail: [UInt8]?
    // Touched only on `processing`.
    private var status = ProbeStatus.fresh()
    private var reader: OfferReader?
    private let router = ReturnRouter()
    private var pendingFingerprint: String?
    private var notifiedFingerprint: String?
    /// App and pay of offers already notified, and when: the same card read again (it slid away and back, or a digit of
    /// its miles was misread) is not another offer (user, Oct 21: "way too many verdicts").
    private var notifiedOffers: [String: Date] = [:]
    /// The last few readings of the card on screen (8 s): an offer goes out when one reading of app, pay, and miles
    /// has at least two votes and more than any other (user, Oct 21: vote across reads).
    private var recentReads: [(fingerprint: String, at: Date)] = []
    private var framesWithoutOffer = 0
    // Order-state reading (screens after accepting): last top-of-screen read, the candidate state, and the last one sent.
    private var lastStatusRead = Date.distantPast
    private var candidateStatus: String?
    private var sentStatus: String?
    private var retriedFingerprint: String?
    private var firstSeen: [String: Date] = [:]
    private var lastOfferAt = Date.distantPast
    /// The app of the last offer or exactly read order screen (for judging loose matches); touched only on `processing`.
    private var recentPlatform: (platform: String, at: Date)?
    // Offer-looking cards that couldn't be read (Oct 17 safety net); touched only on `processing`.
    private var unreadStreak = 0
    private var lastUnreadAlert = Date.distantPast
    private var creditTimer: DispatchSourceTimer?

    override init() {
        super.init()
        Signal.loaded.post()
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        Signal.started.post()
        // End shift in the app also stops screen reading (user, Oct 23: ending the shift but forgetting the reader
        // started a new shift right away).
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                handler.finishBroadcastWithError(NSError(domain: "Lumen", code: 1,
                                                         userInfo: [NSLocalizedDescriptionKey: "Shift ended. __APP_NAME__ stopped reading offers."]))
            }, Signal.stopReading.name as CFString, nil, .deliverImmediately)
        NotificationActions.register()
        // Posted before any heavy work, so it arrives even if the extension is terminated later.
        notify(id: "broadcast-started", title: "__APP_NAME__ is reading offers",
               body: "Leave screen reading on. Each offer card will show its verdict here.")
        gate.lock(); active = true; gate.unlock()
        router.startLocation()
        // Keep a fresh drive-back measurement for stage-1 verdicts (one Apple Maps route per minute).
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 60)
        timer.setEventHandler { [weak self] in self?.router.refreshCredit() }
        timer.resume()
        creditTimer = timer
        processing.async {
            self.status = .fresh()
            self.status.status = "observing"
            self.reader = OfferReader()
            if self.reader == nil {
                self.status.failureCode = "reader_unavailable"
                Signal.readerFailed.post()
                self.notify(id: "reader-failed", title: "__APP_NAME__ can't read offers", body: "The offer reader failed to load in the capture extension.")
            }
            self.publish()
        }
    }

    private func notify(id: String, title: String, body: String, thread: String = "status", userInfo: [AnyHashable: Any] = [:],
                        category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    override func broadcastPaused() { changeState("paused", active: false) }
    override func broadcastResumed() { changeState("observing", active: true) }
    override func broadcastFinished() {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        Signal.finished.post()
        router.stopLocation()
        creditTimer?.cancel(); creditTimer = nil
        changeState("stopped", active: false)
    }

    private func changeState(_ value: String, active: Bool) {
        gate.lock(); self.active = active; gate.unlock()
        processing.async {
            self.status.status = value
            self.publish()
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // Audio and microphone buffers are ignored. No audio permission is requested.
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        let rawOrientation = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                              attachmentModeOut: nil) as? NSNumber
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation?.uint32Value ?? 1) ?? .up
        gate.lock()
        let sinceOCR = now.timeIntervalSince(lastScheduled)
        let shouldProcess = active && !busy && (sinceOCR >= 2 || (changePending && sinceOCR >= Self.minChangeOCRInterval))
        if shouldProcess { busy = true; lastScheduled = now; changePending = false }
        let shouldSense = active && !sensing && !shouldProcess && now.timeIntervalSince(lastSensed) >= Self.senseInterval
        if shouldSense { sensing = true; lastSensed = now }
        gate.unlock()
        if shouldSense {
            sensingQueue.async { self.sense(pixelBuffer, orientation: orientation) }
        }
        guard shouldProcess else { return }
        processing.async {
            defer { self.gate.lock(); self.busy = false; self.gate.unlock() }
            autoreleasepool {
                // Broadcast extensions have a small memory limit (about 50 MB). Only the lower part of the screen,
                // where all three apps draw offer cards, is read, at a reduced size, with the lighter recognizer.
                let input = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
                let lines = self.recognize(input, top: 1 - Double(Self.readFraction), bottom: 1, level: .fast, maxWidth: 900)
                self.status.framesAnalyzed += 1
                Signal.frame.post()
                self.status.lastAnalyzedAt = Date()
                self.status.recognizedLineCount = lines.count
                self.status.priceTokenCount = lines.filter { $0.text.range(of: #"\$\s*\d+(?:\.\d{2})?"#, options: .regularExpression) != nil }.count
                self.status.distanceTokenCount = lines.filter { $0.text.range(of: #"\b\d+(?:\.\d+)?\s*(?:mi|miles)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }.count
                self.status.failureCode = self.reader == nil ? "reader_unavailable" : nil
                do { try self.handleOffer(lines, frame: input, capturedAt: now) }
                catch { self.status.failureCode = "reader_failed" }
                // OCR strings go out of scope here; only offer fields reach storage.
                self.publish()
            }
        }
    }

    /// Cheap change detection on the card area; never stores the thumbnail beyond the last comparison.
    private func sense(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        defer { gate.lock(); sensing = false; gate.unlock() }
        autoreleasepool {
            let input = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
            let extent = input.extent
            let card = input.cropped(to: CGRect(x: extent.minX, y: extent.minY + extent.height * 0.05,
                                                width: extent.width, height: extent.height * 0.5))
            let scale = 24 / extent.width
            let small = card.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let bounds = small.extent.integral
            let width = Int(bounds.width), height = Int(bounds.height)
            guard width > 4, height > 4 else { return }
            var thumbnail = [UInt8](repeating: 0, count: width * height)
            imageContext.render(small, toBitmap: &thumbnail, rowBytes: width, bounds: bounds, format: .L8, colorSpace: nil)
            gate.lock()
            if let previous = lastThumbnail, previous.count == thumbnail.count {
                var total = 0
                for i in 0..<thumbnail.count { total += abs(Int(thumbnail[i]) - Int(previous[i])) }
                if Double(total) / Double(thumbnail.count) > Self.changeThreshold { changePending = true }
            }
            lastThumbnail = thumbnail
            gate.unlock()
        }
    }

    /// Two-stage verdict (roadmap §3): an immediate stage-1 notification from the card and cached values, then the
    /// refined verdict after routing; a second notification only when it changes the recommendation. Every offer —
    /// accepted or not — is written to the journal with its timings (roadmap §7, §47).
    /// Return lookup order: the card's drop-off text; else the drop-off pins on the card's map; else the
    /// worst-case bounds from the restaurant address or current position. After 12 seconds the offer is finalized without it.
    private func handleOffer(_ lines: [OfferReader.Line], frame: CIImage, capturedAt: Date) throws {
        guard let reader else { return }
        let ocrDoneAt = Date()
        guard var summary = try reader.summarize(lines, at: capturedAt) else {
            framesWithoutOffer += 1
            if framesWithoutOffer >= 2 { notifiedFingerprint = nil; pendingFingerprint = nil; retriedFingerprint = nil; recentReads = [] }
            // Looks like an offer but can't be read (e.g. a redesigned card): say so instead of staying silent.
            if reader.status(lines)?.state == "unread_offer" { unreadStreak += 1 } else { unreadStreak = 0 }
            if unreadStreak >= 2, capturedAt.timeIntervalSince(lastUnreadAlert) > 90 {
                lastUnreadAlert = capturedAt
                notify(id: "unread-offer-\(Int(capturedAt.timeIntervalSince1970))", title: "__APP_NAME__ couldn't read this offer",
                       body: "Check the pay and miles yourself. You can add it afterwards with ＋.", thread: "offers")
            }
            readOrderState(lines, frame: frame, at: capturedAt)
            return
        }
        var cardLines = lines
        var usedAccurate = false
        // Miles unread (the fast recognizer can miss Grubhub's large numbers): read the card once more, accurately.
        if summary.outboundMilliMiles == nil, summary.fingerprint != retriedFingerprint {
            retriedFingerprint = summary.fingerprint
            let accurate = recognize(frame, top: 1 - Double(Self.readFraction), bottom: 1, level: .accurate, maxWidth: 1000)
            if let better = try reader.summarize(accurate, at: capturedAt), better.outboundMilliMiles != nil {
                summary = better
                cardLines = accurate
                usedAccurate = true
            }
        }
        framesWithoutOffer = 0
        lastOfferAt = capturedAt
        recentPlatform = (summary.platform, capturedAt)
        status.offersRead += 1
        if firstSeen[summary.fingerprint] == nil { firstSeen[summary.fingerprint] = capturedAt }
        if firstSeen.count > 200 { firstSeen = firstSeen.filter { capturedAt.timeIntervalSince($0.value) < 3600 } }
        guard summary.fingerprint != notifiedFingerprint else { return }
        // Votes across the last reads (user, Oct 21: "this app doesn't work if reading isn't perfect"): a misread digit
        // rarely repeats, so the reading most frames agree on, at least twice and ahead of any other, goes out.
        recentReads = recentReads.filter { capturedAt.timeIntervalSince($0.at) < 8 && $0.fingerprint.hasPrefix(summary.platform + "|") }
        recentReads.append((summary.fingerprint, capturedAt))
        var tally: [String: Int] = [:]
        for read in recentReads { tally[read.fingerprint, default: 0] += 1 }
        let votes = tally[summary.fingerprint] ?? 0
        let rival = tally.filter { $0.key != summary.fingerprint }.values.max() ?? 0
        guard votes >= 2, votes > rival else { return }
        notifiedFingerprint = summary.fingerprint
        pendingFingerprint = nil
        let sameOffer = summary.fingerprint.split(separator: "|").prefix(2).joined(separator: "|")
        notifiedOffers = notifiedOffers.filter { capturedAt.timeIntervalSince($0.value) < 90 }
        guard notifiedOffers[sameOffer] == nil else { return }
        notifiedOffers[sameOffer] = capturedAt
        // DoorDash "Deliver by": minutes come from the clock shown in the status bar (top left).
        if summary.needsClock, let clock = statusBarClock(frame),
           let timed = try reader.summarize(cardLines, at: capturedAt, clockText: clock) {
            summary = timed
        }
        let seenAt = firstSeen[summary.fingerprint] ?? capturedAt
        let offerId = "\(summary.platform)-\(Int(seenAt.timeIntervalSince1970))-\(Self.fnv(summary.fingerprint))"
        let ms = { (date: Date) in Int((date.timeIntervalSince(seenAt) * 1000).rounded()) }

        // One notification per offer, with the finished verdict (user, Oct 21: "no verdict … until the calculations are
        // done"). The quick worst-case verdict is still worked out for the journal (prediction vs refined), not shown.
        let preliminary = (try? reader.preliminary(summary, credit: router.recentCredit)) ?? (word: "Unreadable", notice: "Check offer")
        let firstNotifiedAt = Date()

        // Stage 2: refined verdict.
        var delivered = false, finalized = false
        var trace: [String] = [] // These three are touched only on `processing`.
        var mapCurrent: (Double, Double)?
        var mapJSON: String? // What the map reader saw (pins, icons, dot, labels), for the collected reading data.
        var timings: [String: Int] = ["ocrDone": ms(ocrDoneAt), "firstNotification": ms(firstNotifiedAt)]
        let router = self.router
        // Last step: the "already driving back to __HOME_NAME__" credit (3 s at most), then storage and any UPDATE.
        let deliver: (ReturnRouter.Route?, String?) -> Void = { route, note in
            self.processing.async {
                guard !delivered else { return }
                delivered = true
                timings["routeDone"] = ms(Date())
                if route == nil { self.status.returnLookupsFailed += 1 }
                self.status.returnDestination = router.homeName
                trace.append("return to " + (router.homeName ?? ReturnDestinationStore.current.name + " (not found yet)"))
                let finish: (ReturnRouter.Leg?, String) -> Void = { credit, how in
                    self.processing.async {
                        guard !finalized else { return }
                        finalized = true
                        trace.append(credit.map { "drive back already planned \(String(format: "%.1f", Double(ReturnRouter.milliMiles($0.meters)) / 1000)) mi \(how)" }
                                     ?? "no drive-back credit (\(how))")
                        let refinedAt = Date()
                        timings["refined"] = ms(refinedAt)
                        var extra: [String: Any] = ["offerId": offerId, "preliminaryNotice": preliminary.notice,
                                                    "latencyFirstMs": ms(firstNotifiedAt), "latencyRefinedMs": ms(refinedAt)]
                        if let fix = router.phoneFix {
                            // Where the offer found the phone (Zones heat map), to ~100 m.
                            extra["waitLat"] = (fix.lat * 1000).rounded() / 1000
                            extra["waitLon"] = (fix.lon * 1000).rounded() / 1000
                        }
                        // Reading data for every offer (user, Oct 21: "We can do 1"): the card's text and what the map reader
                        // saw on screen — never coordinates, street names, or the drop-off places worked out from them.
                        extra["cardLines"] = Self.cardText(cardLines, below: summary.mapBottom)
                        if let snapshot = mapJSON.flatMap(Self.mapSnapshot) { extra["mapSnapshot"] = snapshot }
                        guard var finalized = try? reader.finalize(summary, route: route, credit: credit, note: note,
                                                                   debug: trace.joined(separator: " · "), at: seenAt, extra: extra) else { return }
                        let update = reader.shouldUpdate(preliminaryWord: preliminary.word, refinedNotice: finalized.offer.notice ?? "")
                        if update, let refined = try? reader.finalize(summary, route: route, credit: credit, note: note,
                                                                      debug: trace.joined(separator: " · "), at: seenAt,
                                                                      extra: extra.merging(["updated": true]) { $1 }) {
                            finalized = refined
                        }
                        self.store(finalized.offer, refined: finalized.object, update: update, timings: timings, usedAccurate: usedAccurate,
                                   positionKnown: router.recentCredit != nil || mapCurrent != nil, preliminary: preliminary,
                                   times: (seen: seenAt, first: firstNotifiedAt, refined: refinedAt))
                    }
                }
                router.credit(mapCurrent: mapCurrent, completion: finish)
                self.processing.asyncAfter(deadline: .now() + 3) { finish(nil, "timed out") }
            }
        }
        let fallback: (String?) -> Void = { mapReason in
            router.estimate(dropoff: summary.dropoffQuery, pickup: summary.pickupQuery, outboundMilliMiles: summary.outboundMilliMiles) { route, note in
                deliver(route, route == nil ? [mapReason.map { "Map: \($0)" }, note].compactMap { $0 }.joined(separator: ". ") : nil)
            }
        }
        // Build 36 cut this to 6 s and the return often wasn't worked out in time, so verdicts fell back to "Accept if
        // return ≤ …" (more maybes, Oct 21). Wait up to 12 s again: the one notification goes out when it's done.
        processing.asyncAfter(deadline: .now() + 12) { deliver(nil, "Apple Maps did not answer within 12 seconds") }
        guard summary.dropoffQuery == nil else {
            trace.append("drop-off text on card")
            return fallback(nil)
        }
        guard let map = mapAnalysis(of: frame, summary: summary, reader: reader) else {
            trace.append("map image unavailable")
            return fallback("map could not be read")
        }
        mapJSON = map.json
        trace.append("map labels read: " + (map.labels.joined(separator: "/").isEmpty ? "none" : map.labels.joined(separator: "/")))
        router.mapPlaces(labels: map.labels, pickup: summary.pickupQuery, pickupName: summary.pickupName) { places, pickupPlace in
            self.processing.async {
                trace.append("towns found in Apple Maps: \(places.count)" + (pickupPlace != nil ? ", restaurant found" : ""))
                let located = try? reader.locate(map, places: places, pickup: pickupPlace, platform: summary.platform,
                                                 pickupCount: summary.pickupCount, phone: router.phoneFix,
                                                 dropoffCount: summary.dropoffCount, outboundMilliMiles: summary.outboundMilliMiles)
                if let debug = located?.debug { trace.append(debug) }
                mapCurrent = located?.current
                guard let located, !located.dropoffs.isEmpty else { return fallback(located?.reason ?? "map could not be read") }
                // The map's store -> drop-offs must fit the app's own trip miles; if they don't, the pins were misread
                // and the map is not used (a bound verdict instead of a wrong one).
                func routeReturn() {
                router.longestReturn(from: located.dropoffs) { leg in
                    guard let leg else { return fallback("no road route from the map's drop-off") }
                    var route = ReturnRouter.Route(kind: "map", milliMiles: ReturnRouter.milliMiles(leg.meters),
                                                   uncertaintyMilliMiles: Int((located.uncertaintyMiles * 1000).rounded()),
                                                   returnMinutes: ReturnRouter.minutes(leg.seconds))
                    // No time on the card (most Grubhub offers): time the trip itself with Apple Maps.
                    guard summary.appMinutes == nil else { return deliver(route, nil) }
                    router.tripDrive(mapCurrent: located.current, pickup: located.pickups.first ?? pickupPlace, dropoffs: located.dropoffs) { seconds in
                        route.tripDriveMinutes = seconds.map(ReturnRouter.minutes)
                        deliver(route, nil)
                    }
                }
                }
                router.tripDistance(mapCurrent: located.current, pickup: located.pickups.first ?? pickupPlace, dropoffs: located.dropoffs) { toPickup, delivery in
                    self.processing.async {
                        if let delivery, let outbound = summary.outboundMilliMiles {
                            let app = Double(outbound) / 1000, routed = delivery / 1609.344, withPickup = routed + (toPickup ?? 0) / 1609.344
                            trace.append(String(format: "map check: store to drop-offs %.1f mi (+%.1f to the store) vs app %.1f mi", routed, (toPickup ?? 0) / 1609.344, app))
                            if routed > app * 1.4 + 1 || withPickup * 1.5 + 1 < app {
                                return fallback(String(format: "the map's drop-offs don't fit the trip's %.1f mi", app))
                            }
                        }
                        routeReturn()
                    }
                }
            }
        }
    }

    /// Saves the refined offer (list + journal) and replaces the stage-1 notification with the real numbers. "UPDATE"
    /// marks a changed recommendation. (Oct 14: keeping the stage-1 line when the verdict agreed left the user looking
    /// at the worst-case floor instead of the real $/mi.)
    private func store(_ offer: LiveOffer, refined: [String: Any], update: Bool, timings: [String: Int], usedAccurate: Bool,
                       positionKnown: Bool, preliminary: (word: String, notice: String), times: (seen: Date, first: Date, refined: Date)) {
        try? LiveOfferStorage.append(offer)
        var userInfo: [AnyHashable: Any] = [:]
        if let value = LiveOfferStorage.notificationValue(offer) { userInfo[LiveOfferStorage.notificationKey] = value }
        let notice = offer.notice ?? offer.detail
        notify(id: offer.offerId ?? offer.id, title: offer.headline,
               body: Verdict(notice: offer.notice).dot + " " + notice + (offer.why.map { "\n" + $0 } ?? ""), thread: "offers", userInfo: userInfo,
               category: NotificationActions.offerCategory)
        Signal.offer.post() // The app shows it on Home and in the Dynamic Island.
        // Journal (addendum §8–11): append-only events — what the card showed, then each prediction with the logic
        // versions behind it. Times carry the local UTC offset so learning can bucket by the driver's own clock.
        let settings = (try? JSONSerialization.jsonObject(with: Data(OfferReader.settingsJSON.utf8))) as? [String: Any] ?? [:]
        let input: [String: Any] = [
            "offerId": offer.offerId ?? offer.id, "seenAt": Self.localTime(times.seen), "preliminaryAt": Self.localTime(times.first),
            "refinedAt": Self.localTime(times.refined), "refined": refined,
            "preliminary": ["word": preliminary.word, "notice": preliminary.notice], "timingsMs": timings,
            "quality": ["accurateOCR": usedAccurate, "positionKnown": positionKnown], "settings": settings,
            "returnTo": ReturnDestinationStore.current.name,
            "appBuild": Int((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "") ?? 0]
        let events = reader?.journalEvents(input) ?? []
        if !events.isEmpty {
            OfferJournal.appendEvents(events)
            publish()
            return
        }
        // Fallback: the schema-1 record, so a script failure never loses the offer.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(offer), var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            record["type"] = "offer.seen"
            record["preliminaryWord"] = preliminary.word
            record["timingsMs"] = timings
            record["quality"] = ["milesRead": offer.outboundMilliMiles != nil, "timeKnown": offer.appMinutes != nil || offer.tripTimeNote != nil,
                                 "returnFound": offer.returnMilliMiles != nil, "positionKnown": positionKnown,
                                 "mapSolved": offer.returnKind == "map", "accurateOCR": usedAccurate, "readerConfidence": offer.confidence]
            OfferJournal.append(record)
        }
        publish()
    }

    /// OCR of a horizontal band of the screen (fractions from the top), in full-screen normalized coordinates.
    private func recognize(_ frame: CIImage, top: Double, bottom: Double, left: Double = 0, right: Double = 1,
                           level: VNRequestTextRecognitionLevel, maxWidth: CGFloat = 1000) -> [OfferReader.Line] {
        let extent = frame.extent
        let band = frame.cropped(to: CGRect(x: extent.minX + extent.width * CGFloat(left), y: extent.minY + extent.height * CGFloat(1 - bottom),
                                            width: extent.width * CGFloat(right - left), height: extent.height * CGFloat(bottom - top)))
        let scale = min(1, maxWidth / extent.width)
        let scaled = band.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = imageContext.createCGImage(scaled, from: scaled.extent) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation -> OfferReader.Line? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
            let box = observation.boundingBox
            return OfferReader.Line(text: candidate.string, x: left + Double(box.minX) * (right - left),
                                    y: top + Double(1 - box.maxY) * (bottom - top),
                                    w: Double(box.width) * (right - left), h: Double(box.height) * (bottom - top))
        }
    }

    /// The status-bar clock, top left ("5:11"), or nil.
    private func statusBarClock(_ frame: CIImage) -> String? {
        let lines = recognize(frame, top: 0, bottom: 0.05, left: 0, right: 0.4, level: .accurate)
        for line in lines {
            if let range = line.text.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) { return String(line.text[range]) }
        }
        return nil
    }

    /// The offer map above the card: town-name text and a 200-pixel-wide RGBA copy for pin detection. Transient.
    /// The card's lines below the map as "y|x|w|h|text", without cross-street lines ("Oak St & Elm St, Town"), at most 40.
    static func cardText(_ lines: [OfferReader.Line], below top: Double) -> [String] {
        lines.filter { $0.y >= top && !($0.text.contains("&") && $0.text.contains(",")) }.prefix(40)
            .map { String(format: "%.4f|%.4f|%.4f|%.4f|", $0.y, $0.x, $0.w, $0.h) + $0.text }
    }

    /// The map reader's view of the screen, for the collected reading data: each pin's screen position, size, and kind
    /// (store / customer, with the icon's shape), the location dot, and town-name labels. Street-name labels are left
    /// out, and nothing here is a map coordinate.
    static func mapSnapshot(_ json: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let found = object["found"] as? [String: Any] else { return nil }
        let r3 = { (v: Any?) -> Double? in (v as? Double).map { ($0 * 1000).rounded() / 1000 } }
        let pins: [[String: Any]] = (found["pins"] as? [[String: Any]] ?? []).map { pin in
            var out: [String: Any] = [:]
            for key in ["centerX", "centerY", "radius", "iconRatio"] { if let v = r3(pin[key]) { out[key] = v } }
            if let kind = pin["kind"] as? String { out["kind"] = kind }
            return out
        }
        let street = #"\b(St|Rd|Ave|Dr|Blvd|Ln|Ct|Cir|Way|Pkwy|Hwy|Pl|Ter|Trl)\b\.?|\d"#
        let labels: [[String: Any]] = (object["labels"] as? [[String: Any]] ?? []).compactMap { label in
            guard let text = label["text"] as? String, text.range(of: street, options: .regularExpression) == nil else { return nil }
            return ["text": text, "x": r3(label["x"]) ?? 0, "y": r3(label["y"]) ?? 0]
        }
        var snapshot: [String: Any] = ["pins": pins, "labels": labels, "style": found["styleName"] as? String ?? ""]
        if let dot = found["currentLocation"] as? [String: Any] { snapshot["dot"] = ["x": r3(dot["x"]) ?? 0, "y": r3(dot["y"]) ?? 0] }
        if let pickups = found["pickupPins"] as? [[String: Any]], !pickups.isEmpty { snapshot["pickupPins"] = pickups.count }
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A notification banner across the top: its time stamp ("now", "2m ago") or an app's name in the top strip.
    static func bannerShown(_ lines: [OfferReader.Line]) -> Bool {
        lines.contains { line in
            line.y < 0.18 && line.text.range(of: #"^(now|\d+\s?[smh] ago)$|__APP_NAME__|DoorDash|Dasher|Uber|Grubhub|Instacart|Messages"#,
                                               options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private func mapAnalysis(of frame: CIImage, summary: OfferReader.Summary, reader: OfferReader) -> OfferReader.MapAnalysis? {
        let extent = frame.extent
        // The whole map from just under the status bar: DoorDash puts pins and town names near the top (Oct 21
        // screenshots; the old 13% cutoff hid a store pin and "Riverside"). Only when a notification banner covers the
        // top is that strip left out — a screen recording sees the banner, not what's under it.
        let bottom = max(0.2, min(summary.mapBottom, 0.6))
        var top = 0.055
        var lines = recognize(frame, top: top, bottom: bottom, level: .fast)
        if Self.bannerShown(lines) {
            top = 0.18
            lines = lines.filter { $0.y >= top }
        }
        let region = frame.cropped(to: CGRect(x: extent.minX, y: extent.minY + extent.height * CGFloat(1 - bottom),
                                              width: extent.width, height: extent.height * CGFloat(bottom - top)))
        // 400 px: enough to see the icon inside each DoorDash pin (storefront vs person, Oct 21); ~30 ms in the reader.
        let pixelScale = 400 / extent.width
        let small = region.transformed(by: CGAffineTransform(scaleX: pixelScale, y: pixelScale))
        guard let smallCG = imageContext.createCGImage(small, from: small.extent.integral) else { return nil }
        let width = smallCG.width, height = smallCG.height
        guard width > 10, height > 10, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = Data(count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Row 0 of the buffer is the top of the image, matching the JavaScript reader.
            context.draw(smallCG, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let aspect = Double(extent.height / extent.width)
        guard let fast = try? reader.analyzeMap(pixels: pixels, width: width, height: height, platform: summary.platform,
                                                top: top, bottom: bottom, aspect: aspect, lines: lines) else { return nil }
        // Fewer than two place names read: read the map's text again with the accurate recognizer (~0.5 s, only then).
        guard fast.labels.count < 2 else { return fast }
        let accurate = recognize(frame, top: top, bottom: bottom, level: .accurate, maxWidth: 1400)
        guard let better = try? reader.analyzeMap(pixels: pixels, width: width, height: height, platform: summary.platform,
                                                  top: top, bottom: bottom, aspect: aspect, lines: accurate) else { return fast }
        return better.labels.count > fast.labels.count ? better : fast
    }

    /// Offer fields for the stage-1 notification's "I accepted" button (before the refined offer exists). No addresses.
    private static func offerStub(_ summary: OfferReader.Summary, offerId: String) -> [AnyHashable: Any] {
        guard let data = summary.json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var stub: [String: Any] = ["offerId": offerId]
        for key in ["platform", "payCents", "merchant", "merchants", "pickupCount", "dropoffCount", "confidence", "outboundMilliMiles"] {
            if let value = object[key], !(value is NSNull) { stub[key] = value }
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: stub), let text = String(data: encoded, encoding: .utf8) else { return [:] }
        return ["offerStub": text]
    }

    /// Not an offer: every 3 s, read the top of the screen too and classify the whole screen as an order state (at the
    /// store, heading to the customer, …). A state is sent to the app once it's seen twice in a row, and only when it
    /// changes. OCR text is dropped right after; only the app and state leave this function.
    private func readOrderState(_ lowerLines: [OfferReader.Line], frame: CIImage, at now: Date) {
        // Every 2 s for 3 minutes after an offer (the pickup screen right after Accept can be on screen only briefly
        // before the driver switches to their own maps), else every 3 s.
        let interval: TimeInterval = now.timeIntervalSince(lastOfferAt) < 180 ? 2 : 3
        guard let reader, now.timeIntervalSince(lastStatusRead) >= interval else { return }
        lastStatusRead = now
        let upper = recognize(frame, top: 0, bottom: 1 - Double(Self.readFraction), level: .fast, maxWidth: 900)
        guard let status = reader.status(upper + lowerLines), LifecycleSignal.states.contains(status.state) else {
            candidateStatus = nil
            return
        }
        // A loose (misread) match is only believed for the app the driver has been using — the last offer or exactly
        // read screen in the past hour. A misread Grubhub drop-off once resembled DoorDash's (scorecard, Oct 18).
        if status.tolerant, let recent = recentPlatform, now.timeIntervalSince(recent.at) < 3600, recent.platform != status.platform {
            candidateStatus = nil
            return
        }
        if !status.tolerant { recentPlatform = (status.platform, now) }
        // Uber's map bar: maybe a store, maybe your zone (Oct 22) — sent as navigation, without a store, read twice.
        let state = status.platform == "uber_eats" && status.state == "heading_to_store" ? "navigating_to_store" : status.state
        // Pickup screens carry their store's code, so the app only accepts an offer from that store (Oct 18 shift).
        let store = LifecycleSignal.storeStates.contains(state) ? LifecycleSignal.storeCode(status.store) : nil
        let key = status.platform + "." + state + (store.map { ".s\($0)" } ?? "")
        // Pickup screens are specific enough to act on at the first read (they're the evidence of an accept, Oct 16
        // field miss); other states, and any loose (misread) match, must be read twice in a row.
        let immediate = (state == "heading_to_store" || state == "at_store") && !status.tolerant
        guard key == candidateStatus || immediate else { candidateStatus = key; return }
        candidateStatus = key
        guard key != sentStatus else { return }
        sentStatus = key
        LifecycleSignal(platform: status.platform, state: state, store: store).post()
    }

    /// FNV-1a, deterministic across launches (Swift's hashValue is not), for stable offer IDs.
    private static func fnv(_ text: String) -> String {
        var h: UInt32 = 0x811c9dc5
        for byte in text.utf8 { h ^= UInt32(byte); h = h &* 0x01000193 }
        return String(h, radix: 16)
    }

    /// ISO 8601 with the phone's local UTC offset ("2026-10-14T18:10:00-05:00") for journal events.
    private static let localFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()
    private static func localTime(_ date: Date) -> String { localFormatter.string(from: date) }

    // Best effort: without a signed App Group the status can't be shared, but reading and notifying continue.
    private func publish() {
        status.updatedAt = Date()
        try? ProbeStorage.write(status)
    }
}
