import SwiftUI
import MapKit

/// Every restaurant __APP_NAME__ has seen on offers or that you arrived at, with waits; search, rename, and merge duplicates.
struct RestaurantsView: View {
    @ObservedObject private var store = RestaurantStore.shared
    @State private var search = ""

    private var shown: [Restaurant] {
        let list = store.restaurants.sorted { ($0.visits, $0.offers) > ($1.visits, $1.offers) }
        guard !search.isEmpty else { return list }
        return list.filter { r in r.aliases.contains { $0.localizedCaseInsensitiveContains(search) } }
    }

    var body: some View {
        List {
            Section {
                ForEach(shown) { r in
                    NavigationLink { RestaurantDetail(restaurantId: r.id) } label: { RestaurantRow(restaurant: r, stat: store.stats[r.id]) }
                }
            }
        }
        .searchable(text: $search, prompt: "Search restaurants")
        .navigationTitle("Restaurants")
        .overlay {
            if store.restaurants.isEmpty {
                ContentUnavailableView("No restaurants yet", systemImage: "fork.knife", description: Text("They appear as offers are read."))
            }
        }
    }
}

struct RestaurantRow: View {
    let restaurant: Restaurant
    let stat: RestaurantStat?
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(restaurant.name).font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(restaurant.platforms, id: \.self) { AppLogo(platform: $0, size: 16) }
                    Text("\(restaurant.offers) offers · \(restaurant.visits) visits").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let average = stat?.averageMinutes {
                Text(String(format: "%.0f min", average)).font(.subheadline.weight(.bold).monospacedDigit())
            }
        }
    }
}

struct RestaurantDetail: View {
    @ObservedObject private var store = RestaurantStore.shared
    @Environment(\.dismiss) private var dismiss
    let restaurantId: String
    @State private var renaming = false
    @State private var newName = ""
    @State private var merging = false

    private var restaurant: Restaurant? { store.restaurants.first { $0.id == restaurantId } }

    var body: some View {
        List {
            if let r = restaurant {
                RestaurantLocationSection(restaurant: r)
                Section {
                    row("Offers seen", "\(r.offers)")
                    row("Your visits", "\(r.visits)")
                    row("Apps", r.platforms.map(Theme.appName).joined(separator: ", "))
                }
                if let stat = store.stats[r.id] {
                    Section("Wait for food") {
                        row("Average", stat.averageMinutes.map { String(format: "%.1f min", $0) } ?? "—")
                        row("Longest", stat.waits > 0 ? String(format: "%.0f min", Double(stat.longestSeconds) / 60) : "—")
                        ForEach([("breakfast", "Breakfast"), ("lunch", "Lunch"), ("dinner", "Dinner"), ("late_night", "Late night"),
                                 ("early_morning", "Early morning")], id: \.0) { key, label in
                            if let p = stat.byPeriod[key] {
                                row(label + " (\(p.waits))", String(format: "%.1f min", p.averageMinutes))
                            }
                        }
                        if !stat.atLeast.isEmpty {
                            row("Left before ready", stat.atLeast.map { "≥ \($0 / 60) min" }.joined(separator: ", "))
                        }
                    }
                }
                Section("Names") {
                    ForEach(r.aliases, id: \.self) { Text($0) }
                    Button("Rename") { newName = r.name; renaming = true }
                    Button("Merge with another restaurant…") { merging = true }
                }
            }
        }
        .navigationTitle(restaurant?.name ?? "Restaurant")
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { store.rename(restaurantId, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $merging) {
            NavigationStack {
                MergePicker(restaurantId: restaurantId) { target in
                    store.merge(restaurantId, into: target)
                    merging = false
                    dismiss()
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}

/// Choose the restaurant this one is a duplicate of: likely matches first (similar name, nearby), then all others.
struct MergePicker: View {
    @ObservedObject private var store = RestaurantStore.shared
    @ObservedObject private var places = RestaurantPlaces.shared
    @Environment(\.dismiss) private var dismiss
    let restaurantId: String
    let onPick: (String) -> Void
    @State private var search = ""
    @State private var confirm: Restaurant?

    var body: some View {
        let suggestions = store.suggestions(for: restaurantId)
        let suggested = Set(suggestions.map(\.id))
        let others = store.restaurants.filter { $0.id != restaurantId && !suggested.contains($0.id)
            && (search.isEmpty || $0.aliases.contains { $0.localizedCaseInsensitiveContains(search) }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let candidates = suggestions.compactMap { s in store.restaurants.first { $0.id == s.id } }
        List {
            if !suggestions.isEmpty && search.isEmpty {
                // Where this one and its likely matches are (user, Oct 19: "i can't figure out which ones to merge").
                if let me = store.restaurants.first(where: { $0.id == restaurantId }) {
                    Section {
                        MergeMap(restaurant: me, candidates: candidates)
                            .frame(height: 220)
                            .listRowInsets(EdgeInsets())
                    } footer: {
                        Text("Purple: this one. Numbers: likely matches.")
                    }
                }
                Section("Likely the same place") {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, r in
                        Button { confirm = r } label: { candidateRow(r, number: index + 1) }
                    }
                }
            }
            Section("All restaurants") {
                ForEach(others) { r in
                    Button { confirm = r } label: { candidateRow(r, number: nil) }
                }
            }
        }
        .onAppear { places.find([restaurantId] + suggestions.map(\.id)) }
        .searchable(text: $search)
        .navigationTitle("Merge into…")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .confirmationDialog("Merge?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { target in
            Button("Merge into \(target.name)") { onPick(target.id) }
        } message: { target in
            Text("Both names, offers, visits, and waits become one restaurant: \(target.name).")
        }
    }

    private func candidateRow(_ r: Restaurant, number: Int?) -> some View {
        HStack(spacing: 10) {
            if let number {
                Text("\(number)").font(.caption.weight(.heavy)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Color.gray, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).foregroundStyle(.primary)
                if let place = placeText(r) { Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if let miles = milesApart(r) { Text(String(format: "%.1f mi apart", miles)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func placeText(_ r: Restaurant) -> String? {
        if r.lat != nil { return "Located from your arrivals" }
        return places.places[r.id]?.address
    }

    private func milesApart(_ r: Restaurant) -> Double? {
        guard let me = store.restaurants.first(where: { $0.id == restaurantId }),
              let a = places.location(of: me)?.coordinate, let b = places.location(of: r)?.coordinate else { return nil }
        return CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1609.344
    }
}

/// This restaurant (purple) and its likely duplicates (numbered), on one map.
struct MergeMap: View {
    @ObservedObject private var places = RestaurantPlaces.shared
    let restaurant: Restaurant
    let candidates: [Restaurant]

    var body: some View {
        Map {
            if let me = places.location(of: restaurant) {
                Marker(restaurant.name, systemImage: "fork.knife", coordinate: me.coordinate).tint(Theme.purple)
            }
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, r in
                if let at = places.location(of: r) {
                    Marker(r.name, monogram: Text("\(index + 1)"), coordinate: at.coordinate).tint(.gray)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }
}

/// The restaurant on a map, and how __APP_NAME__ knows where it is (user, Oct 19).
struct RestaurantLocationSection: View {
    @ObservedObject private var places = RestaurantPlaces.shared
    let restaurant: Restaurant

    var body: some View {
        Section {
            if let at = places.location(of: restaurant) {
                Map(initialPosition: .region(MKCoordinateRegion(center: at.coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))) {
                    Marker(restaurant.name, systemImage: "fork.knife", coordinate: at.coordinate).tint(Theme.purple)
                }
                .frame(height: 190)
                .listRowInsets(EdgeInsets())
                VStack(alignment: .leading, spacing: 2) {
                    if at.fromArrivals {
                        Text("From your arrivals here").font(.subheadline)
                    } else {
                        Text("Apple Maps match (approximate)").font(.subheadline)
                        if let place = places.places[restaurant.id] {
                            Text([place.title, place.address].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Open in Maps") {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: at.coordinate))
                    item.name = restaurant.name
                    item.openInMaps()
                }
            } else if places.searching {
                Label("Looking it up on Apple Maps…", systemImage: "magnifyingglass").foregroundStyle(.secondary)
            } else {
                Label("Location unknown. It's saved the first time you arrive there.", systemImage: "mappin.slash").foregroundStyle(.secondary)
            }
        }
        .onAppear { if restaurant.lat == nil { places.find([restaurant.id]) } }
    }
}
