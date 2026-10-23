import SwiftUI

/// Where the app can go (user, Oct 15: DoorDash-style menu instead of tabs — the app has outgrown four tabs).
enum AppSection: String, CaseIterable, Identifiable {
    case home, offers, earnings, breakdown, zones, restaurants, account, diagnostics
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .offers: return "Offers"
        case .earnings: return "Earnings"
        case .breakdown: return "Breakdown"
        case .zones: return "Zones"
        case .restaurants: return "Restaurants"
        case .account: return "Account"
        case .diagnostics: return "Diagnostics"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .offers: return "list.bullet.rectangle"
        case .earnings: return "dollarsign.circle"
        case .breakdown: return "chart.pie"
        case .zones: return "map"
        case .restaurants: return "fork.knife"
        case .account: return "person.crop.circle"
        case .diagnostics: return "wrench.and.screwdriver"
        }
    }

    /// Main destinations above the divider; the rest below it (like DoorDash's Messages/Help).
    static let main: [AppSection] = [.home, .offers, .earnings, .breakdown, .zones, .restaurants, .account]
}

@MainActor
final class MenuState: ObservableObject {
    @Published var isOpen = false
    @Published var section: AppSection = .home
    @Published var showingHelp = false

    init() {
        // Simulator screenshots in the cloud build: -tab 0…3 pick a screen; 4 shows Home with the menu open.
        switch PreviewData.initialTab {
        case 1: section = .offers
        case 2: section = .earnings
        case 3: section = .account
        case 4: isOpen = true
        case 5: section = .breakdown
        default: break
        }
    }

    func go(_ section: AppSection) {
        withAnimation(.easeOut(duration: 0.22)) {
            self.section = section
            isOpen = false
        }
    }

    func toggle() { withAnimation(.easeOut(duration: 0.22)) { isOpen.toggle() } }
}

/// The ☰ button at the top left of every main screen.
struct MenuButton: View {
    @EnvironmentObject private var menu: MenuState
    var body: some View {
        Button { menu.toggle() } label: {
            Image(systemName: "line.3.horizontal").font(.title3.weight(.semibold))
        }
        .accessibilityLabel("Menu")
    }
}

extension View {
    /// Adds the ☰ menu button to a main screen's navigation bar.
    func menuButton() -> some View {
        toolbar { ToolbarItem(placement: .topBarLeading) { MenuButton() } }
    }
}

/// The panel that slides in from the left: who/what at the top, destinations, then Help and Diagnostics.
struct SideMenu: View {
    @EnvironmentObject private var menu: MenuState
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var shifts = ShiftStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                Text("__APP_NAME__").font(.largeTitle.weight(.bold))
                HStack(spacing: 6) {
                    Circle().fill(model.isReading ? Theme.neonGreen : Color.gray).frame(width: 8, height: 8)
                    Text(model.screenCaptured ? model.statusText : "Not reading offers").font(.subheadline).foregroundStyle(.secondary)
                }
                if shifts.current != nil, let m = shifts.metrics {
                    Text("This shift · " + ShiftFormat.money(m.earningsCents) + " · " + ShiftFormat.rate(m.perOnlineHourCents, "hr"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 20)

            ForEach(AppSection.main) { section in row(section) }
            Divider().padding(.vertical, 10).padding(.horizontal, 20)
            Button { menu.isOpen = false; menu.showingHelp = true } label: { label("Help", "questionmark.circle", selected: false) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("menu.help")
            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
    }

    private func row(_ section: AppSection) -> some View {
        Button { menu.go(section) } label: { label(section.title, section.icon, selected: menu.section == section) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu." + section.rawValue)
    }

    private func label(_ title: String, _ icon: String, selected: Bool) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.title3).frame(width: 30)
            Text(title).font(.title3.weight(selected ? .bold : .regular))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(selected ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
    }
}
