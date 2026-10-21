import SwiftUI
import MapKit

/// The heat map from core/shift.js `zoneHeat` (the JSON it returns).
struct ZoneHeat: Decodable, Equatable {
    struct Cell: Decodable, Equatable, Identifiable {
        let lat: Double, lon: Double, latSpan: Double, lonSpan: Double, value: Double
        var id: String { "\(lat),\(lon)" }
        var corners: [CLLocationCoordinate2D] {
            let a = latSpan / 2, b = lonSpan / 2
            return [.init(latitude: lat - a, longitude: lon - b), .init(latitude: lat - a, longitude: lon + b),
                    .init(latitude: lat + a, longitude: lon + b), .init(latitude: lat + a, longitude: lon - b)]
        }
    }
    struct Zone: Decodable, Equatable, Identifiable {
        let lat: Double, lon: Double, value: Double
        let near: [String]
        let offers: Int, goodOffers: Int
        let goodPerHour: Double?
        var id: String { "\(lat),\(lon)" }
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }
    struct Place: Decodable, Equatable, Identifiable {
        let id: String, name: String, lat: Double, lon: Double, source: String, offers: Int, good: Int
    }
    let offers: Int, goodOffers: Int, placedOffers: Int, fromSpots: Int
    let hours: Double
    let confidence: String
    let cells: [Cell]
    let zones: [Zone]
    let restaurants: [Place]
    let unplaced: [String]
}

/// Where to wait (user, Oct 19): a heat map of where good offers come from, for a time of day and weekdays/weekends,
/// with the best 3 spots. Built from every offer read (better offers and recent ones count more), the restaurants'
/// positions, and where offers found the phone — so it sharpens with every shift.
struct ZonesView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var restaurants = RestaurantStore.shared
    @ObservedObject private var places = RestaurantPlaces.shared
    @ObservedObject private var shifts = ShiftStore.shared
    @State private var part = ZonesView.currentPart()
    @State private var days = "all"
    @State private var heat: ZoneHeat?
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    static let parts: [(key: String, label: String)] = [("breakfast", "Bfast"), ("lunch", "Lunch"), ("dinner", "Dinner"),
                                                         ("late_night", "Late"), ("all", "All")]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Picker("Time of day", selection: $part) {
                        ForEach(Self.parts, id: \.key) { Text($0.label).tag($0.key) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Days", selection: $days) {
                        Text("All days").tag("all"); Text("Weekdays").tag("weekday"); Text("Weekends").tag("weekend")
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal).padding(.bottom, 8)
                map
                spots
            }
            .navigationTitle("Zones")
            .navigationBarTitleDisplayMode(.inline)
            .menuButton()
        }
        .sensoryFeedback(.selection, trigger: part)
        .sensoryFeedback(.selection, trigger: days)
        .onAppear { recompute(locate: true) }
        .onChange(of: part) { recompute(locate: true) }
        .onChange(of: days) { recompute(locate: false) }
        .onChange(of: places.searching) { _, busy in if !busy { recompute(locate: false) } }
        .onChange(of: model.offers.count) { recompute(locate: true) }
    }

    private var map: some View {
        Map(position: $camera) {
            ForEach(heat?.cells ?? []) { cell in
                MapPolygon(coordinates: cell.corners)
                    .foregroundStyle(Self.color(cell.value).opacity(0.12 + 0.5 * cell.value))
            }
            ForEach(Array((heat?.restaurants ?? []).prefix(80))) { r in
                Annotation(r.name, coordinate: .init(latitude: r.lat, longitude: r.lon), anchor: .center) {
                    Circle().fill(.white).frame(width: 7, height: 7).overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1))
                }
                .annotationTitles(.hidden)
            }
            ForEach(Array((heat?.zones ?? []).enumerated()), id: \.element.id) { index, zone in
                Annotation("Spot \(index + 1)", coordinate: zone.coordinate, anchor: .center) {
                    Text("\(index + 1)").font(.caption.weight(.heavy)).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(Theme.purple, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
                .annotationTitles(.hidden)
            }
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }
        .overlay(alignment: .topTrailing) { legend }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Fewer").font(.caption2)
            LinearGradient(colors: [Self.color(0.1), Self.color(0.5), Self.color(1)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 60, height: 6).clipShape(Capsule())
            Text("More good offers").font(.caption2)
        }
        .padding(6).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
    }

    @ViewBuilder private var spots: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let heat, !heat.zones.isEmpty {
                ForEach(Array(heat.zones.enumerated()), id: \.element.id) { index, zone in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.subheadline.weight(.heavy)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(Theme.purple, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(zone.near.isEmpty ? "Where offers found you" : "Near " + zone.near.prefix(2).map(Self.short).joined(separator: ", "))
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(Self.detail(zone)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Go") { Self.directions(to: zone, index: index) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation { camera = .region(MKCoordinateRegion(center: zone.coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)) }
                    }
                }
            } else if heat != nil {
                Text("Not enough offers for this time yet. The map fills in as __APP_NAME__ reads offers on your shifts.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let heat { Text(footer(heat)).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
    }

    private func footer(_ heat: ZoneHeat) -> String {
        let label = ["early": "Early guess", "building": "Getting sharper", "solid": "Solid"][heat.confidence] ?? ""
        var text = "\(label) · \(heat.placedOffers) of \(heat.offers) offers on the map"
        if heat.hours > 0 { text += " · \(String(format: "%.1f", heat.hours)) h online" }
        let missing = heat.unplaced.count
        if places.searching { text += " · finding restaurants on Apple Maps…" } else if missing > 0 { text += " · \(missing) restaurants not found" }
        return text
    }

    private func recompute(locate: Bool) {
        let offers: [[String: Any]] = model.offers.filter { !DemoData.isDemo($0.offerId) }.map { o in
            var row: [String: Any] = ["id": o.offerId ?? o.id, "platform": o.platform, "seenAt": ISO8601DateFormatter().string(from: o.seenAt),
                                      "tone": o.tone]
            if let merchants = o.merchants { row["merchants"] = merchants }
            if let merchant = o.merchant { row["merchant"] = merchant }
            if let notice = o.notice { row["notice"] = notice }
            if let hourly = o.hourlyCents { row["hourlyCents"] = hourly }
            if let lat = o.waitLat, let lon = o.waitLon { row["waitLat"] = lat; row["waitLon"] = lon }
            return row
        }
        let shiftRows: [[String: Any]] = (shifts.history + [shifts.current].compactMap { $0 }).map { s in
            var row: [String: Any] = ["startedAt": ISO8601DateFormatter().string(from: s.startedAt)]
            if let end = s.endedAt { row["endedAt"] = ISO8601DateFormatter().string(from: end) }
            return row
        }
        let input = "{\"restaurants\":\(restaurants.databaseJSON),\"offers\":\(ShiftEngine.json(offers)),\"places\":\(places.json),"
            + "\"shifts\":\(ShiftEngine.json(shiftRows)),\"part\":\(ShiftEngine.json(part)),\"days\":\(ShiftEngine.json(days)),"
            + "\"now\":\(ShiftEngine.json(ISO8601DateFormatter().string(from: Date()))),\"offsetMinutes\":\(ShiftEngine.offsetMinutes),"
            + "\"targetHourlyCents\":\(model.rules.hourlyTargetCents)}"
        let result = ShiftEngine.decode(ZoneHeat.self, ShiftEngine.call("zoneHeatJSON", [input]))
        if result != heat { heat = result }
        if locate, let unplaced = result?.unplaced, !unplaced.isEmpty { places.find(unplaced) }
    }

    // MARK: Helpers

    static func color(_ value: Double) -> Color {
        // Yellow → orange → red as the zone gets better.
        Color(hue: 0.15 * (1 - min(1, max(0, value))), saturation: 0.95, brightness: 0.95)
    }

    static func short(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
    }

    static func detail(_ zone: ZoneHeat.Zone) -> String {
        var parts = ["\(zone.offers) offers", "\(zone.goodOffers) good"]
        if let rate = zone.goodPerHour { parts.append(String(format: "%.1f good/hr", rate)) }
        return parts.joined(separator: " · ")
    }

    static func directions(to zone: ZoneHeat.Zone, index: Int) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: zone.coordinate))
        item.name = "__APP_NAME__ spot \(index + 1)"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    /// The period it is now (core/shift.js DAY_PARTS: breakfast 6:00, lunch 11:00, dinner 15:30, late night 22:30).
    static func currentPart(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        switch minute {
        case 360..<660: return "breakfast"
        case 660..<930: return "lunch"
        case 930..<1350: return "dinner"
        case 90..<360: return "all" // Early morning: too few offers to map on its own.
        default: return "late_night"
        }
    }
}
