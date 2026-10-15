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
                Text(model.destinationShared
                     ? "Applies from the next offer; no need to restart reading. The drive back already planned is measured to this place too."
                     : "This install has no shared App Group, so the offer reader can't see this choice and keeps using __HOME_NAME__.")
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
                if place == model.destination { Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(Theme.purple) }
            }
        }
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
