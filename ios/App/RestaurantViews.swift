import SwiftUI

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
            } footer: {
                Text("Built from offer cards and the stores you tick as arrived. If one place shows up under two names, open it and tap Merge.")
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
                Section {
                    row("Offers seen", "\(r.offers)")
                    row("Your visits", "\(r.visits)")
                    row("Apps", r.platforms.map(Theme.appName).joined(separator: ", "))
                    if r.lat != nil { row("Location", "saved from your arrivals") }
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
        List {
            if !suggestions.isEmpty && search.isEmpty {
                Section("Likely the same place") {
                    ForEach(suggestions) { s in
                        Button { confirm = store.restaurants.first { $0.id == s.id } } label: {
                            HStack {
                                Text(s.name).foregroundStyle(.primary)
                                Spacer()
                                if let miles = s.miles { Text(String(format: "%.1f mi apart", miles)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            Section("All restaurants") {
                ForEach(others) { r in
                    Button { confirm = r } label: { Text(r.name).foregroundStyle(.primary) }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Merge into…")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .confirmationDialog("Merge?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { target in
            Button("Merge into \(target.name)") { onPick(target.id) }
        } message: { target in
            Text("Both names, offers, visits, and waits become one restaurant: \(target.name).")
        }
    }
}
