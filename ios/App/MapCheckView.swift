import SwiftUI

/// What the reader saw on an offer's map and which pins it chose (user, Oct 23: "see the map pins it estimates to see how
/// accurate it is per order"). Drawn from the offer's saved map snapshot: pin positions on the screen, the driver's dot
/// and town names — never real-world places. Compare it with the map the app showed.
struct MapSnapshot: Decodable {
    struct Pin: Decodable { let centerX: Double; let centerY: Double; let radius: Double?; let kind: String? }
    struct Point: Decodable { let x: Double; let y: Double }
    struct Label: Decodable { let text: String; let x: Double; let y: Double }
    struct Chosen: Decodable { let pickups: [Point]; let dropoffs: [Point] }
    let pins: [Pin]
    let labels: [Label]
    let dot: Point?
    let chosen: Chosen?

    static func parse(_ text: String?) -> MapSnapshot? {
        text.flatMap { try? JSONDecoder().decode(MapSnapshot.self, from: Data($0.utf8)) }
    }

    enum Role { case pickup, dropoff(Int), other }

    /// Each pin's role: the chosen point nearest its centre (a chosen point is the pin's tip, just below the centre).
    func role(of pin: Pin) -> Role {
        guard let chosen else { return .other }
        let near = { (p: Point) in hypot(p.x - pin.centerX, p.y - pin.centerY) < max(0.06, (pin.radius ?? 0.04) * 2.5) }
        if chosen.pickups.contains(where: near) { return .pickup }
        if let i = chosen.dropoffs.firstIndex(where: near) { return .dropoff(i + 1) }
        return .other
    }
}

struct MapCheckView: View {
    let offer: LiveOffer
    let snapshot: MapSnapshot

    /// The part of the screen the map covered: from the top down past the lowest pin, dot or label.
    private var span: (top: Double, bottom: Double) {
        let ys = snapshot.pins.map(\.centerY) + snapshot.labels.map(\.y) + [snapshot.dot?.y].compactMap { $0 }
        return (max(0, (ys.min() ?? 0.1) - 0.06), min(1, (ys.max() ?? 0.5) + 0.06))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let (top, bottom) = span
                let w = geo.size.width, h = geo.size.height
                let place = { (x: Double, y: Double) in CGPoint(x: x * w, y: (y - top) / (bottom - top) * h) }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised)
                    ForEach(Array(snapshot.labels.enumerated()), id: \.offset) { _, label in
                        Text(label.text).font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                            .position(place(label.x, label.y))
                    }
                    if let dot = snapshot.dot {
                        Circle().fill(Color.blue).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .position(place(dot.x, dot.y))
                    }
                    ForEach(Array(snapshot.pins.enumerated()), id: \.offset) { _, pin in
                        marker(snapshot.role(of: pin), kind: pin.kind).position(place(pin.centerX, pin.centerY))
                    }
                }
            }
            .frame(height: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
            HStack(spacing: 14) {
                legend(Theme.purple, "Store")
                legend(Theme.neonGreen, "Drop-off")
                legend(Theme.secondaryText.opacity(0.5), "Not used")
                legend(.blue, "You")
            }
            .font(.caption)
            Text(summary).font(.footnote).foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder private func marker(_ role: MapSnapshot.Role, kind: String?) -> some View {
        switch role {
        case .pickup:
            badge(Theme.purple, Image(systemName: "fork.knife"))
        case .dropoff(let n):
            badge(Theme.neonGreen, Text("\(n)").font(.caption.weight(.heavy)))
        case .other:
            Circle().stroke(Theme.secondaryText.opacity(0.6), lineWidth: 2).frame(width: 22, height: 22)
                .overlay(Image(systemName: kind == "store" ? "fork.knife" : kind == "customer" ? "person.fill" : "circle.fill")
                    .font(.system(size: 9)).foregroundStyle(Theme.secondaryText))
        }
    }

    private func badge<Content: View>(_ color: Color, _ content: Content) -> some View {
        Circle().fill(color).frame(width: 28, height: 28)
            .overlay(content.font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ground))
            .overlay(Circle().stroke(Theme.ground, lineWidth: 2))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 9, height: 9); Text(text).foregroundStyle(Theme.secondaryText) }
    }

    /// "Map about 4.1 mi wide · return ≈ 9.5 mi ±0.8 mi", or why the map wasn't used.
    private var summary: String {
        var parts: [String] = []
        if snapshot.chosen == nil { parts.append("The map wasn't used for this offer") }
        if let debug = offer.returnDebug, let range = debug.range(of: #"map [\d.]+ mi wide"#, options: .regularExpression) {
            parts.append(String(debug[range]).replacingOccurrences(of: "map ", with: "Map about "))
        }
        if offer.returnKind == "map", let ret = offer.returnMilliMiles {
            parts.append(String(format: "return ≈ %.1f mi", Double(ret) / 1000))
        } else if let kind = offer.returnKind, let ret = offer.returnMilliMiles {
            parts.append(String(format: "return %.1f mi from ", Double(ret) / 1000) + (kind == "worst_case" ? "the longest case" : "the drop-off text"))
        }
        return parts.isEmpty ? "Pins as the reader saw them." : parts.joined(separator: " · ")
    }
}
