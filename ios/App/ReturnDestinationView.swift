import SwiftUI
import MapKit

/// Choose where offers' return trips end (user, Oct 14: not always __HOME_NAME__). __HOME_NAME__ is always available;
/// added places are found with Apple Maps search, named by the user, and kept for quick switching.
struct ReturnDestinationView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var search = PlaceSearch()
    @State private var pending: ReturnDestination?
    @State private var label = ""
    @State private var lookupFailed = false

    var body: some View {
        List {
            Section {
                row(.homeBase)
                ForEach(model.savedDestinations) { place in
                    row(place).swipeActions { Button("Remove", role: .destructive) { model.removeDestination(place) } }
                }
            } header: {
                Text("Return to")
            } footer: {
                Text(model.headingHome ? "Heading home: offers return to Home until the shift ends." : "Applies from the next offer.")
            }
            Section("Add a place") {
                TextField("Search address or place", text: $search.query)
                    .textInputAutocapitalization(.words).autocorrectionDisabled()
                ForEach(search.results, id: \.self) { result in
                    Button {
                        search.resolve(result) { place in
                            guard let place else { lookupFailed = true; return }
                            label = place.name
                            pending = place
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title).foregroundStyle(.primary)
                            if !result.subtitle.isEmpty { Text(result.subtitle).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if lookupFailed { Text("Apple Maps couldn't find that place. Try another result.").font(.caption).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Return destination")
        .alert("Name this place", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            TextField("Name (e.g. Home)", text: $label)
            Button("Use it") {
                if let place = pending { model.chooseDestination(place.renamed(label)) }
                pending = nil
                search.query = ""
                lookupFailed = false
            }
            Button("Cancel", role: .cancel) { pending = nil }
        }
    }

    private func row(_ place: ReturnDestination) -> some View {
        Button { model.chooseDestination(place) } label: {
            HStack {
                Image(systemName: place.isDefault ? "music.note.house.fill" : "mappin.circle.fill").foregroundStyle(Theme.purple)
                Text(place.name).foregroundStyle(.primary)
                Spacer()
                if place == model.destination && !model.headingHome { Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(Theme.purple) }
            }
        }
    }
}

/// Home (user, Oct 28: "another address bar, so you can set your home … stored locally"): where the last order of a
/// shift should take you. Found with Apple Maps search and kept on this phone only. `thenHeadHome`: opened from
/// Heading home, which turns on once Home is set.
struct HomeAddressView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlaceSearch()
    var thenHeadHome = false
    @State private var lookupFailed = false

    var body: some View {
        List {
            if let home = model.home {
                Section {
                    Label(home.query ?? "Home", systemImage: "house.fill")
                    Button("Remove home", role: .destructive) { model.setHome(nil) }
                } header: {
                    Text("Home")
                } footer: {
                    Text("On this phone only.")
                }
            }
            Section {
                TextField("Search your address", text: $search.query)
                    .textInputAutocapitalization(.words).autocorrectionDisabled()
                ForEach(search.results, id: \.self) { result in
                    Button {
                        search.resolve(result) { place in
                            guard let place else { lookupFailed = true; return }
                            let address = [result.title, result.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
                            model.setHome(ReturnDestination(name: "Home", latitude: place.latitude, longitude: place.longitude, query: address))
                            search.query = ""
                            lookupFailed = false
                            if thenHeadHome { model.setHeadingHome(true); dismiss() }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title).foregroundStyle(.primary)
                            if !result.subtitle.isEmpty { Text(result.subtitle).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if lookupFailed { Text("Apple Maps couldn't find that place. Try another result.").font(.caption).foregroundStyle(.orange) }
            } header: {
                Text(model.home == nil ? "Set your home" : "Change it")
            } footer: {
                if model.home == nil { Text("On this phone only.") }
            }
        }
        .navigationTitle("Home")
        .toolbar { if thenHeadHome { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } }
    }
}

/// The last order of a shift (user, Oct 28: "for when it's your last order. And you're planning on going home, and you
/// want the next order to take you there"): offers are judged on what they add to the drive home. Asks for Home the
/// first time; turns off when the shift ends.
struct HeadingHomeButton: View {
    @EnvironmentObject private var model: AppModel
    var compact = false
    @State private var settingHome = false

    var body: some View {
        Button {
            if model.home == nil { settingHome = true } else { model.setHeadingHome(!model.headingHome) }
        } label: {
            let on = model.headingHome
            if compact {
                Label(on ? "Heading home" : "Head home", systemImage: on ? "house.fill" : "house")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .foregroundStyle(on ? Theme.ground : Theme.secondaryText)
                    .background(on ? Theme.neonGreen : Theme.raised, in: Capsule())
            } else {
                HStack(spacing: 12) {
                    Image(systemName: on ? "house.fill" : "house").font(.title3.weight(.bold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Heading home").font(.headline)
                        Text(on ? "Next offer judged on the way home" : "Last order takes you home").font(.caption)
                            .foregroundStyle(on ? Theme.ground.opacity(0.75) : Theme.secondaryText)
                    }
                    Spacer()
                    Text(on ? "On" : "Off").font(.subheadline.weight(.bold))
                }
                .foregroundStyle(on ? Theme.ground : .primary)
                .padding(.horizontal, 16).frame(height: 60)
                .background(on ? Theme.neonGreen : Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: model.headingHome)
        .accessibilityLabel(model.headingHome ? "Heading home, on" : "Heading home, off")
        .sheet(isPresented: $settingHome) { NavigationStack { HomeAddressView(thenHeadHome: true) } }
    }
}

/// Apple Maps type-ahead for places near the phone (any zone; Fairview if the position is unknown).
/// Results arrive on the main thread.
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    @Published var query = "" {
        didSet {
            if query.trimmingCharacters(in: .whitespaces).isEmpty { results = [] } else { completer.queryFragment = query }
        }
    }
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        let here = LocationAccess.manager.location?.coordinate ?? CLLocationCoordinate2D(latitude: __AREA_LAT__, longitude: __AREA_LON__)
        completer.region = MKCoordinateRegion(center: here, latitudinalMeters: 150_000, longitudinalMeters: 150_000)
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = query.isEmpty ? [] : Array(completer.results.prefix(8))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { results = [] }

    /// The picked suggestion's coordinate; completion on the main thread.
    func resolve(_ suggestion: MKLocalSearchCompletion, completion: @escaping (ReturnDestination?) -> Void) {
        MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion)).start { response, _ in
            let place = response?.mapItems.first.map { item in
                ReturnDestination(name: suggestion.title, latitude: item.placemark.coordinate.latitude,
                                  longitude: item.placemark.coordinate.longitude, query: nil)
            }
            DispatchQueue.main.async { completion(place) }
        }
    }
}
