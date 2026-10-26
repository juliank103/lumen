import SwiftUI
import Combine
import UserNotifications

/// App-wide state for all tabs, refreshed every 3 seconds: capture status, offers (from the shared store or the
/// delivered notifications, kept permanently in the app's own archive), and notification settings.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var probe: ProbeStatus?
    @Published private(set) var offers: [LiveOffer] = []
    @Published private(set) var storageAvailable = true
    @Published private(set) var screenCaptured = false
    @Published private(set) var notificationStatus = "checking"
    @Published private(set) var bannerStatus = "checking"
    @Published private(set) var summaryStatus = "checking"
    @Published private(set) var journalCount = 0
    @Published private(set) var destination = ReturnDestinationStore.current
    @Published private(set) var savedDestinations = ReturnDestinationStore.saved
    @Published private(set) var destinationShared = ReturnDestinationStore.isShared
    @Published private(set) var rules = RulesStore.current
    @Published private(set) var rulesShared = RulesStore.isShared
    /// Offers the driver deleted from history; never re-added from the shared list or notifications.
    private var deletedOffers: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "deletedOffers") ?? [])

    /// Offers swiped away (or X'd) on the Dash; they stay in the Offers tab.
    @Published private(set) var dismissed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "dismissedOffers") ?? [])
    private var timer: AnyCancellable?
    private var offerObserver: AnyCancellable?
    /// Reader accuracy per app (Diagnostics; a Home warning when an app's reading suddenly gets worse), every 5 minutes.
    @Published private(set) var readerHealth: ReaderHealth?
    private var readerHealthAt = Date.distantPast
    private var archive: [LiveOffer] = OfferArchive.load()

    init() {
        LifecycleSync.shared.model = self
        timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { await self?.refresh() }
        }
        // The reader just posted an offer: pick it up now (Dynamic Island verdict) instead of at the next tick.
        offerObserver = NotificationCenter.default.publisher(for: ExtensionSignals.offerReceived).sink { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func start() async {
        if PreviewData.isActive {
            // Simulator screenshots in the cloud build: invented offers, no permission prompts.
            offers = PreviewData.offers
            screenCaptured = true
            RestaurantStore.shared.update(offers: offers, trips: [PreviewData.trip])
            timer = nil
            return
        }
        // The capture extension posts offer notifications; permission is asked here, in the app.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        LocationAccess.manager.requestWhenInUseAuthorization()
        MileageRate.migrate()
        // Hand the current settings to the reader again (the bridge, when there's no App Group).
        RulesStore.save(rules)
        ReturnDestinationStore.republish()
        TimingStore.save(TimingStore.current)
        await refresh()
    }

    /// Only the newest offer ever shows on Home (user, Oct 21: "way too many offers to dismiss"): dismissing it, taking it,
    /// or a newer one arriving makes it go, and older offers never come back. Offers live on the Offers page.
    var latestOffer: LiveOffer? {
        guard let offer = offers.last, !dismissed.contains(offer.id), TripStore.shared.trip(for: offer.offerId ?? offer.id) == nil else { return nil }
        return offer
    }

    /// Big card for 45 s (the apps give about that long to decide), then one line until 3 minutes, then gone by itself.
    static let offerHeroSeconds: TimeInterval = 45
    static let offerLineSeconds: TimeInterval = 180

    var currentOffer: LiveOffer? {
        if PreviewData.isActive && !PreviewData.showsOffer { return nil }
        guard let offer = latestOffer, PreviewData.isActive || Date().timeIntervalSince(offer.seenAt) < Self.offerLineSeconds else { return nil }
        return offer
    }

    func dismiss(_ offer: LiveOffer) {
        dismissed.insert(offer.id)
        UserDefaults.standard.set(Array(dismissed.suffix(500)), forKey: "dismissedOffers")
    }

    var isReading: Bool {
        screenCaptured && (probe.map { $0.status == "observing" } ?? true)
    }

    var statusText: String {
        if !screenCaptured { return "Not reading offers" }
        if let probe, let last = probe.lastAnalyzedAt, Date().timeIntervalSince(last) > 12 { return "Waiting for the screen" }
        return "Reading offers"
    }

    func refresh() async {
        screenCaptured = UIScreen.main.isCaptured
        do { probe = try ProbeStorage.read(); storageAvailable = true }
        catch { probe = nil; storageAvailable = false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .ephemeral: notificationStatus = "Allowed"
        case .provisional: notificationStatus = "Delivered quietly"
        case .denied: notificationStatus = "Off"
        case .notDetermined: notificationStatus = "Not asked yet"
        @unknown default: notificationStatus = "Unknown"
        }
        bannerStatus = settings.alertSetting != .enabled || settings.alertStyle == .none ? "Off"
            : settings.alertStyle == .alert ? "Persistent" : "Temporary"
        summaryStatus = settings.scheduledDeliverySetting == .enabled ? "On (holds offers)" : "Off"
        var list = (try? LiveOfferStorage.read()) ?? []
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        for note in delivered {
            if let offer = LiveOfferStorage.fromNotification(note.request.content.userInfo),
               !list.contains(where: { $0.id == offer.id }) { list.append(offer) }
        }
        // Offer screens kept for training ride on the verdict notifications: into Photos.
        TrainingCapture.collect(from: delivered)
        // Keep every offer in the app's own archive (the shared list holds 100; notifications get cleared).
        var known = Set(archive.map(\.id)), added: [LiveOffer] = []
        for offer in list where !known.contains(offer.id) && !deletedOffers.contains(offer.offerId ?? offer.id) {
            let kept = LiveOffer.keepsReadingData ? offer : offer.withoutReadingData()
            archive.append(kept); known.insert(offer.id); added.append(kept)
        }
        trimReadingData()
        if !added.isEmpty {
            archive.sort { $0.seenAt < $1.seenAt }
            OfferArchive.append(added)
        }
        if archive.count != offers.count || archive.last?.id != offers.last?.id { offers = archive }
        journalCount = OfferJournal.readShared().count
        if screenCaptured { ShiftStore.shared.startIfNeeded() }
        TripActivityController.offer = currentOffer
        if Date().timeIntervalSince(readerHealthAt) > 300 {
            readerHealthAt = Date()
            readerHealth = ReaderHealth.compute(offers: offers)
            updateTimeFactors()
            // Every 5 minutes, hand the settings to the reader again: the bridge's pasteboard can be cleared.
            RulesStore.save(rules)
            ReturnDestinationStore.republish()
            RestaurantStore.shared.shareKnownPlaces()
            Bridge.publish("reader2-trial", Data((UserDefaults.standard.bool(forKey: "reader2Trial") ? "on" : "off").utf8))
            TrainingCapture.republish()
        }
        TripActivityController.refresh(TripStore.shared.active)
        RestaurantStore.shared.update(offers: offers, trips: TripStore.shared.history + [TripStore.shared.active].compactMap { $0 })
    }

    /// How much longer each app's orders really take than estimates for offers with no time (Grubhub), for the reader.
    private func updateTimeFactors() {
        guard !PreviewData.isActive else { return }
        let trips = TripStore.shared.history + [TripStore.shared.active].compactMap { $0 }
        let shifts = (ShiftStore.shared.history + [ShiftStore.shared.current].compactMap { $0 }).filter { !DemoData.isDemo($0.id) }
        let input = "{\"offers\":\(ShiftEngine.json(encodable: offers.filter { !DemoData.isDemo($0.offerId) })),"
            + "\"trips\":\(ShiftEngine.json(encodable: trips.filter { !DemoData.isDemo($0.id) })),"
            + "\"shifts\":\(ShiftEngine.json(encodable: shifts))}"
        struct Share: Decodable { let share: Double; let orders: Int }
        var timing = TimingStore.current
        if let factors = ShiftEngine.decode([String: Double].self, ShiftEngine.call("timeFactorsJSON", [input])) { timing.factors = factors }
        if let share = ShiftEngine.decode(Share.self, ShiftEngine.call("returnShareJSON", [input])) {
            timing.returnShare = share.share
            timing.returnShareOrders = share.orders
        }
        TimingStore.save(timing)
    }

    func setRules(_ new: Rules) {
        rulesShared = RulesStore.save(new)
        rules = RulesStore.current
    }

    func chooseDestination(_ choice: ReturnDestination) {
        destinationShared = ReturnDestinationStore.select(choice)
        reloadDestinations()
    }

    func removeDestination(_ place: ReturnDestination) {
        ReturnDestinationStore.remove(place)
        reloadDestinations()
    }

    private func reloadDestinations() {
        destination = ReturnDestinationStore.current
        savedDestinations = ReturnDestinationStore.saved
        destinationShared = destinationShared && ReturnDestinationStore.isShared
    }

    /// Adds offers that aren't in the archive yet (restore from a backup, or demo data). Returns how many were added.
    @discardableResult
    func importOffers(_ incoming: [LiveOffer]) -> Int {
        let known = Set(archive.map(\.id))
        let added = incoming.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return 0 }
        archive = (archive + added).sorted { $0.seenAt < $1.seenAt }
        OfferArchive.append(added)
        offers = archive
        return added.count
    }

    /// Deletes an offer from history, and its order and steps if it was taken (user, Oct 15).
    func deleteOffer(_ offerId: String) {
        deletedOffers.insert(offerId)
        UserDefaults.standard.set(Array(deletedOffers.suffix(5000)), forKey: "deletedOffers")
        removeOffers { ($0.offerId ?? $0.id) == offerId }
        TripStore.shared.deleteOrder(offerId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [offerId])
    }

    private var readingDataTrimmedAt = Date.distantPast

    /// Reading data is kept 30 days (a few KB an offer), and dropped at once when turned off; checked hourly.
    func trimReadingData(force: Bool = false) {
        guard force || Date().timeIntervalSince(readingDataTrimmedAt) > 3600 else { return }
        readingDataTrimmedAt = Date()
        let cutoff = Date().addingTimeInterval(-30 * 86_400), keep = LiveOffer.keepsReadingData
        guard archive.contains(where: { ($0.cardLines != nil || $0.mapSnapshot != nil) && (!keep || $0.seenAt < cutoff) }) else { return }
        archive = archive.map { (!keep || $0.seenAt < cutoff) ? $0.withoutReadingData() : $0 }
        OfferArchive.rewrite(archive)
        offers = archive
    }

    func removeOffers(where test: (LiveOffer) -> Bool) {
        archive.removeAll(where: test)
        OfferArchive.rewrite(archive)
        offers = archive
    }

    var hasDemoData: Bool { offers.contains { DemoData.isDemo($0.offerId) } || TripStore.shared.history.contains { DemoData.isDemo($0.id) } }

    func loadDemoData() {
        let demo = DemoData.make()
        importOffers(demo.offers)
        TripStore.shared.importTrips(demo.trips)
        ShiftStore.shared.importShifts(demo.shifts)
        RestaurantStore.shared.update(offers: offers, trips: TripStore.shared.history + [TripStore.shared.active].compactMap { $0 })
    }

    func removeDemoData() {
        removeOffers { DemoData.isDemo($0.offerId) }
        TripStore.shared.removeTrips { DemoData.isDemo($0.id) }
        ShiftStore.shared.removeShifts { DemoData.isDemo($0.id) }
        RestaurantStore.shared.rebuild(offers: offers, trips: TripStore.shared.history + [TripStore.shared.active].compactMap { $0 })
    }

    func sendTestNotification(after seconds: TimeInterval?) {
        let content = UNMutableNotificationContent()
        content.title = "__APP_NAME__ test"
        content.body = seconds == nil ? "🟢 Notifications from __APP_NAME__ work." : "🟢 If this dropped down over another app, offer pop-ups will too."
        let trigger = seconds.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test-\(Date().timeIntervalSince1970)", content: content, trigger: trigger))
    }
}

/// Every offer seen, in the app's own container (survives the shared list's 100-offer limit and cleared notifications).
enum OfferArchive {
    /// One offer per line, appended as offers arrive (review: the old single JSON file was rewritten on every offer).
    private static var url: URL? { folder?.appendingPathComponent("offer-archive.jsonl") }
    /// The single-file archive from builds 28–40, read once and converted.
    private static var legacyURL: URL? { folder?.appendingPathComponent("offer-archive.json") }
    private static var folder: URL? { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func load() -> [LiveOffer] {
        guard !PreviewData.isActive, let url else { return [] }
        if let legacy = legacyURL, let data = try? Data(contentsOf: legacy), let old = try? decoder.decode([LiveOffer].self, from: data) {
            rewrite(old)
            try? FileManager.default.removeItem(at: legacy)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        let offers = text.split(separator: "\n").compactMap { line -> LiveOffer? in
            guard let offer = try? decoder.decode(LiveOffer.self, from: Data(line.utf8)), !seen.contains(offer.id) else { return nil }
            seen.insert(offer.id)
            return offer
        }
        return offers.sorted { $0.seenAt < $1.seenAt }
    }

    static func append(_ offers: [LiveOffer]) {
        guard !PreviewData.isActive, let url, !offers.isEmpty else { return }
        var data = Data()
        for offer in offers {
            guard let line = try? encoder.encode(offer) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Replaces the whole archive (after removing demo data).
    static func rewrite(_ offers: [LiveOffer]) {
        guard !PreviewData.isActive, let url else { return }
        try? FileManager.default.removeItem(at: url)
        append(offers)
    }
}
