import SwiftUI

/// DoorDash-style layout (user, Oct 15): one screen at a time, with a ☰ menu sliding in from the left to switch
/// between Home, Offers, Earnings, Restaurants, Past shifts, Account, Help, and Diagnostics. (Was four tabs.)
struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var signals = ExtensionSignals()
    @StateObject private var menu = MenuState()
    @State private var openedBackupResult: String?

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
        .preferredColorScheme(PreviewData.forcedScheme ?? .dark)
        .environmentObject(model)
        .environmentObject(signals)
        .environmentObject(menu)
        .sheet(isPresented: $menu.showingHelp) { DashHelp() }
        // A backup opened from the Files app (Share → __APP_NAME__): restore it (user, Oct 22).
        .onOpenURL { url in
            guard url.isFileURL else { return }
            openedBackupResult = BackupRestore.restore(url, model: model)
        }
        .alert("Restore", isPresented: Binding(get: { openedBackupResult != nil }, set: { if !$0 { openedBackupResult = nil } })) {
            Button("OK") { openedBackupResult = nil }
        } message: {
            Text(openedBackupResult ?? "")
        }
        .task { await model.start() }
    }

    @ViewBuilder private var current: some View {
        switch menu.section {
        case .home: DashTab()
        case .offers: OffersTab()
        case .earnings: StatsTab()
        case .breakdown: BreakdownView()
        case .planner: PlannerView()
        case .zones: ZonesView()
        case .restaurants: NavigationStack { RestaurantsView().menuButton() }
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
    @ObservedObject private var shifts = ShiftStore.shared

    var body: some View {
        NavigationStack {
            // Redesign (user, Oct 21): one state at a time — on an order, an offer in, or waiting.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SetupHealthCard(issues: model.setupIssues)
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        VStack(alignment: .leading, spacing: 16) {
                            // A new offer shows even on an order (stacking); the trip stays below it.
                            if let offer = model.currentOffer, trips.active != nil {
                                // On an order: one compact row, the trip stays the screen (user, Oct 21).
                                HomeOfferRow(offer: offer) { withAnimation { model.dismiss(offer) } }
                            } else if let offer = model.currentOffer {
                                if PreviewData.isActive || context.date.timeIntervalSince(offer.seenAt) < AppModel.offerHeroSeconds {
                                    HomeOfferCard(offer: offer) { withAnimation { model.dismiss(offer) } }
                                } else {
                                    LastOfferRow(offer: offer) { withAnimation { model.dismiss(offer) } }
                                }
                            }
                            if let trip = trips.active {
                                HomeOnOrder(trip: trip)
                            } else if model.currentOffer != nil {
                                HomeShiftStrip()
                            } else {
                                HomeWaiting()
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.ground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if trips.active == nil && (shifts.current == nil || !model.screenCaptured) {
                    DashBottomBar(trip: nil, reading: model.screenCaptured, destination: model.destination.name, rules: model.rules)
                }
            }
            .navigationTitle("__APP_NAME__")
            .navigationBarTitleDisplayMode(.inline)
            // Haptics (user, Oct 21): a new offer by its verdict, each trip step, shift start/end, a dismissal.
            .sensoryFeedback(trigger: model.currentOffer?.id) { _, new in
                guard new != nil, let offer = model.currentOffer else { return nil }
                switch Verdict(notice: offer.notice) {
                case .accept: return .success
                case .decline: return .warning
                case .maybe: return .impact(weight: .medium)
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: trips.active?.steps.count)
            .sensoryFeedback(.impact(weight: .heavy), trigger: shifts.current?.id)
            .sensoryFeedback(.impact(weight: .light), trigger: model.dismissed.count)
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
    @ObservedObject private var shifts = ShiftStore.shared

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
                .accessibilityHint("Records this step of the order")
            } else {
                if shifts.current == nil {
                    // Starting a shift lives on Home (user, Oct 16); it also starts screen reading if that's off.
                    // Not reading: only open the broadcast sheet; the shift starts when the reader says it started
                    // (readingStarted). Starting it here swapped this button out while its sheet was up, and the
                    // broadcast that followed never loaded the reader (Oct 27: no verdicts; the top toggle worked).
                    Button {
                        if reading { shifts.startIfNeeded() } else { BroadcastLauncher.shared.open() }
                    } label: {
                        Text("Start shift").font(.headline.weight(.bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .background(Theme.purple, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(PickerHost().frame(width: 1, height: 1).opacity(0.01))
                } else if !reading {
                    BroadcastButton(running: false)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .background(Theme.ground)
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
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    Text("Or: Control Center → hold Screen Recording → __APP_NAME__ Reader.")
                }
                Section("Offer pop-ups") {
                    Text("Turn on Settings › Notifications › Screen Sharing.")
                }
                Section("Orders") {
                    Text("Tap I accepted, then the big button at each stop. Undo fixes mistakes.")
                    Text("Swipe or tap ✕ to dismiss an offer.")
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
