import SwiftUI

/// A store name typed by hand, with matches from the restaurant list as you type (user, Oct 15: "everywhere … you can
/// manually input a restaurant should use our database"). Tapping a match fills the field; any other name still works.
/// Used inside a Form: the field and its matches are separate rows.
struct StoreField: View {
    let prompt: String
    @Binding var text: String
    /// The order's app: its stores come first.
    var platform: String? = nil
    @ObservedObject private var restaurants = RestaurantStore.shared
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $text)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .focused($focused)
        if focused {
            ForEach(matches) { restaurant in
                Button {
                    text = restaurant.name
                    focused = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                        Text(restaurant.name).foregroundStyle(.primary).lineLimit(1)
                        Spacer()
                        ForEach(restaurant.platforms.prefix(3), id: \.self) { AppLogo(platform: $0, size: 16) }
                    }
                }
            }
        }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Best five: names (or other names) starting with what's typed, then containing it; the app's own stores and the
    /// most visited first. With nothing typed, the most used stores.
    private var matches: [Restaurant] {
        let query = Self.fold(text)
        let scored: [(Restaurant, Int)] = restaurants.restaurants.compactMap { r in
            let names = ([r.name] + r.aliases).map(Self.fold)
            if !query.isEmpty, names.contains(query) { return nil }
            var score = r.visits * 3 + r.offers
            if !query.isEmpty {
                if names.contains(where: { $0.hasPrefix(query) || $0.contains(" " + query) }) { score += 100_000 }
                else if names.contains(where: { $0.contains(query) }) { score += 50_000 }
                else { return nil }
            }
            if let platform, r.platforms.contains(platform) { score += 10_000 }
            return (r, score)
        }
        if !query.isEmpty, restaurants.restaurants.contains(where: { Self.fold($0.name) == query }) { return [] }
        return scored.sorted { $0.1 > $1.1 }.prefix(5).map(\.0)
    }
}
