import SwiftUI

/// DoorDash-style layout (user, Oct 15): one screen at a time, with a ☰ menu sliding in from the left to switch
/// between Home, Offers, Earnings, Restaurants, Past shifts, Account, Help, and Diagnostics. (Was four tabs.)
struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var signals = ExtensionSignals()
    @StateObject private var menu = MenuState()

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                current
                    .disabled(menu.isOpen)
                if menu.isOpen {
                    Color.black.opacity(0.45).ignoresSafeArea()
                        .onTapGesture { menu.toggle() }
                        .transition(.opacity)
                    SideMenu()
                        .frame(width: min(340, geometry.size.width * 0.8))
                        .transition(.move(edge: .leading))
                        .gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.width < -60 { menu.toggle() } })
                }
            }
        }
        .tint(Theme.purple)
        .preferredColorScheme(PreviewData.forcedScheme)
        .environmentObject(model)
        .environmentObject(signals)
        .environmentObject(menu)
        .sheet(isPresented: $menu.showingHelp) { DashHelp() }
        .task { await model.start() }
    }

    @ViewBuilder private var current: some View {
        switch menu.section {
        case .home: DashTab()
        case .offers: OffersTab()
        case .earnings: StatsTab()
        case .restaurants: NavigationStack { RestaurantsView().menuButton() }
        case .shifts: NavigationStack { ShiftHistoryView().menuButton() }
        case .account: AccountTab()
        case .diagnostics: NavigationStack { DiagnosticsView().menuButton() }
        }
    }
}

// MARK: Dash

/// Home screen, simple while driving. Review (Oct 15): the action used most during a trip — the next step — sits in the
/// thumb zone at the bottom; Start/Stop moved to the status at the top; offers older than 90 s collapse to one line;
/// settings problems show only when there are some; compact title.
struct DashTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var trips = TripStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SetupHealthCard(issues: model.setupIssues)
                    if let trip = trips.active {
                        TripCard(trip: trip)
                    }
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        if let offer = model.currentOffer {
                            if PreviewData.isActive || context.date.timeIntervalSince(offer.seenAt) < 90 {
                                OfferHero(offer: offer) { withAnimation { model.dismiss(offer) } }
                            } else {
                                LastOfferRow(offer: offer) { withAnimation { model.dismiss(offer) } }
                            }
                        } else if trips.active == nil {
                            Text(model.isReading ? "Waiting for the next offer…" : "Start reading to get a verdict on every offer.")
                                .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
                        }
                    }
                    ShiftSummaryCard()
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom) {
                DashBottomBar(trip: trips.active, reading: model.screenCaptured, destination: model.destination.name, rules: model.rules)
            }
            .navigationTitle("Lumen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Like DoorDash's centered "This week" pill: the reading status, which also starts/stops reading.
                ToolbarItem(placement: .principal) {
                    ReadingToggle(reading: model.isReading, capturing: model.screenCaptured, text: model.statusText)
                }
                // An offer the reader missed, typed in from the card (user, Oct 15).
                ToolbarItem(placement: .topBarTrailing) { AddButton() }
            }
            .menuButton()
        }
    }
}

/// The bottom of the Dash, in the thumb zone: during a trip, the next step (big); otherwise the rules and, when
/// reading is off, the Start button.
struct DashBottomBar: View {
    let trip: Trip?
    let reading: Bool
    let destination: String
    let rules: Rules

    var body: some View {
        VStack(spacing: 10) {
            if let trip, let next = trip.actions.first {
                Button { TripStore.shared.perform(next) } label: {
                    Text(next.label).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).frame(minHeight: 60)
                        .foregroundStyle(.white)
                        .background(Theme.purple, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Records this step of the trip")
            } else {
                NavigationLink { ReturnDestinationView() } label: {
                    HStack(spacing: 4) {
                        Text("\(rules.perMileText)/mi incl. return to \(destination) · \(rules.hourlyText)")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if !reading { BroadcastButton(running: false) }
            }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .background(Color(.systemBackground).shadow(.drop(color: .black.opacity(0.08), radius: 6, y: -2)))
    }
}

/// Reading status at the top; tap it to start or stop reading (opens the system broadcast sheet).
struct ReadingToggle: View {
    let reading: Bool
    let capturing: Bool
    let text: String

    var body: some View {
        Button { BroadcastLauncher.shared.open() } label: {
            HStack(spacing: 7) {
                Circle().fill(reading ? Theme.neonGreen : Color.gray).frame(width: 9, height: 9)
                Text(capturing ? text : "Start reading").font(.subheadline.weight(.semibold))
                    .foregroundStyle(capturing ? Color.primary : Theme.purple)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .background(PickerHost().frame(width: 1, height: 1).opacity(0.01))
        .accessibilityLabel(capturing ? "\(text). Double-tap to stop reading offers." : "Start reading offers")
    }
}

/// An offer past its decision window, as one line.
struct LastOfferRow: View {
    let offer: LiveOffer
    let onDismiss: () -> Void

    private var title: String {
        let pay: String = (Double(offer.payCents) / 100).formatted(.currency(code: "USD"))
        guard let miles = offer.outboundMilliMiles else { return "Last offer · " + pay }
        return "Last offer · " + pay + String(format: " · %.1f mi", Double(miles) / 1000)
    }

    var body: some View {
        HStack(spacing: 10) {
            AppLogo(platform: offer.platform, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(offer.notice ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            AcceptButton(offer: offer, compact: true)
            Button(action: onDismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .accessibilityLabel("Dismiss offer")
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// How to start reading and use the trip buttons, out of the way until asked for.
struct DashHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Start reading offers") {
                    Text("Tap Start reading offers, then Start Broadcast.")
                    Text("Or: Control Center → press and hold Screen Recording → Lumen Reader → Start Broadcast.")
                }
                Section("Offer pop-ups") {
                    Text("Settings › Notifications › Screen Sharing › Allow Notifications must be on, or offers only land in Notification Center.")
                }
                Section("Trips") {
                    Text("Tap I accepted this on an offer (or ✓ I accepted on its notification). Then tick each store and drop-off with the big button or from the trip notification. Undo fixes a mistaken tap.")
                    Text("Swipe an offer sideways or tap ✕ to dismiss it.")
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct StatusPill: View {
    let reading: Bool
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(reading ? Theme.neonGreen : Color.gray).frame(width: 10, height: 10)
            Text(text).font(.subheadline.weight(.bold))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.card, in: Capsule())
    }
}

/// The latest offer, big and simple: app, pay, miles, restaurant, and the neon verdict.
struct OfferHero: View {
    let offer: LiveOffer
    var onDismiss: (() -> Void)? = nil
    @State private var dragX: CGFloat = 0
    @ScaledMetric(relativeTo: .largeTitle) private var paySize: CGFloat = 44
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AppLogo(platform: offer.platform, size: 30)
                Spacer()
                Text(offer.seenAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Dismiss offer")
                }
            }
            Text((Double(offer.payCents) / 100).formatted(.currency(code: "USD")))
                .font(.system(size: paySize, weight: .heavy, design: .rounded))
            Text([offer.outboundMilliMiles.map { String(format: "%.1f mi", Double($0) / 1000) }, offer.merchant].compactMap { $0 }.joined(separator: " · "))
                .font(.headline).foregroundStyle(.secondary).lineLimit(1)
            VerdictChip(notice: offer.notice, large: true)
            AcceptButton(offer: offer)
        }
        .dasherCard()
        // Swipe sideways to dismiss an offer you didn't take (user, Oct 14).
        .offset(x: dragX)
        .opacity(1 - min(0.6, Double(abs(dragX)) / 300))
        .simultaneousGesture(DragGesture(minimumDistance: 20)
            .onChanged { value in
                if onDismiss != nil, abs(value.translation.width) > abs(value.translation.height) { dragX = value.translation.width }
            }
            .onEnded { value in
                if abs(value.translation.width) > 110, abs(value.translation.width) > abs(value.translation.height) { onDismiss?() }
                withAnimation(.spring) { dragX = 0 }
            })
    }
}
