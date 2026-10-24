import SwiftUI

/// Everyday settings only (user, Oct 14): rules, return location, goal and vehicle cost, notifications, location,
/// data export, privacy. Everything technical is one tap deeper in Advanced & diagnostics.
struct AccountTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var shifts = ShiftStore.shared
    @AppStorage("vehicleCostCentsPerMile") private var costPerMile = 0
    @AppStorage("mileageDeductionCents") private var deductionCents = 67
    @AppStorage("keepReadingData") private var keepReadingData = true
    @State private var editingDeduction = false
    @State private var deductionText = ""
    @AppStorage(AutoSteps.enabledKey) private var autoSteps = true
    @AppStorage(AudioCues.enabledKey) private var audioCues = true
    @State private var editingGoal = false
    @ObservedObject private var goals = GoalStore.shared
    @State private var editingCost = false
    @State private var costText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Stepper(value: Binding(get: { model.rules.centsPerMile },
                                           set: { model.setRules(Rules(centsPerMile: $0, hourlyTargetCents: model.rules.hourlyTargetCents)) }),
                            in: 50...300, step: 5) {
                        row("Pay per mile", model.rules.perMileText + ", incl. return")
                    }
                    Stepper(value: Binding(get: { model.rules.hourlyTargetCents },
                                           set: { model.setRules(Rules(centsPerMile: model.rules.centsPerMile, hourlyTargetCents: $0)) }),
                            in: 1000...6000, step: 100) {
                        row("Hourly target", model.rules.hourlyText)
                    }
                    NavigationLink { ReturnDestinationView() } label: { row("Return location", model.destination.name) }
                } header: {
                    HStack {
                        Text("Your rules")
                        InfoNote(title: "Your rules", text: "Miles include the drive back.")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        // How much of the drive back counts toward $/hr (user, Oct 24: orders often come on the way back).
                        let timing = TimingStore.current
                        if timing.returnShare < 1 {
                            Text("$/hr counts \(Int((timing.returnShare * 100).rounded()))% of the drive back: the share you really lose before the next order, from \(timing.returnShareOrders) of your orders.")
                        } else {
                            Text("$/hr counts the whole drive back until 5 of your orders show how often the next one comes on the way.")
                        }
                        if !model.rulesShared { Text("Reader uses $1/mi and $25/hr on this install.") }
                    }
                }
                Section {
                    Toggle("Tick order steps automatically", isOn: $autoSteps)
                    Toggle("Say when an order is accepted or delivered", isOn: $audioCues)
                    if audioCues { Button("Test the voice") { AudioCues.shared.test() } }
                } header: {
                    HStack {
                        Text("Automatic")
                        InfoNote(title: "Automatic order steps", text: "Uses the apps' screens and your location. Undo fixes a wrong step.")
                    }
                }
                Section("Goals and costs") {
                    Button { editingGoal = true } label: {
                        row("Earnings goals", goalSummary)
                    }
                    .foregroundStyle(.primary)
                    Button { costText = costPerMile > 0 ? String(costPerMile) : ""; editingCost = true } label: {
                        row("Vehicle cost per mile", costPerMile > 0 ? "\(costPerMile)¢" : "Not set")
                    }
                    .foregroundStyle(.primary)
                    Button { deductionText = String(deductionCents); editingDeduction = true } label: {
                        row("Mileage deduction", "\(deductionCents)¢ per mile")
                    }
                    .foregroundStyle(.primary)
                }
                Section {
                    row("Notifications", model.notificationStatus)
                    row("Location", LocationAccess.statusText)
                    if LocationAccess.manager.authorizationStatus != .authorizedAlways {
                        Button("Allow location always") { LocationAccess.requestAlways() }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Needs Screen Sharing notifications on and Location set to Always.")
                }
                // Polish pass (Oct 16): one job per screen — the store list and diagnostics live here, not in the menu.
                Section("More") {
                    NavigationLink("Restaurants") { RestaurantsView() }
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                }
                Section {
                    ExportButton()
                    RestoreButton()
                    // Reading data (user, Oct 21): card text and what the map reader saw, to keep improving the reader.
                    Toggle("Save reading data", isOn: $keepReadingData)
                        .onChange(of: keepReadingData) { _, on in if !on { model.trimReadingData(force: true) } }
                    NavigationLink { GridwiseImportView() } label: { Label("Import from Gridwise", systemImage: "square.and.arrow.down.on.square") }
                    NavigationLink("Privacy") { PrivacyView() }
                } header: {
                    HStack {
                        Text("Your data")
                        InfoNote(title: "Backups", text: "Export before installing a new build.")
                    }
                }
            }
            .navigationTitle("Account")
            .menuButton()
            .goalEditor(isPresented: $editingGoal)
            .alert("Mileage deduction", isPresented: $editingDeduction) {
                TextField("Cents per mile, e.g. 67", text: $deductionText).keyboardType(.numberPad)
                Button("Save") { deductionCents = max(0, min(200, Int(deductionText) ?? 67)) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The Deduction tile on Earnings is your miles times this rate (the IRS standard mileage rate).")
            }
            .alert("Vehicle cost per mile", isPresented: $editingCost) {
                TextField("Cents, e.g. 30", text: $costText).keyboardType(.numberPad)
                Button("Save") { costPerMile = max(0, min(200, Int(costText) ?? 0)) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Gas, wear, and insurance per mile. Used for earnings after costs in Stats.")
            }
        }
    }

    /// "Shift $150 · Day $200 · Week $1,000", or "None".
    private var goalSummary: String {
        let parts = [("Shift", shifts.defaultGoalCents), ("Day", goals.dailyCents), ("Week", goals.weeklyCents)]
            .compactMap { label, cents in cents.map { label + " " + ShiftFormat.money($0) } }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    private func row(_ label: String, _ text: String) -> some View {
        HStack { Text(label); Spacer(); Text(text).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("__APP_NAME__ reads only what is on your screen. It never signs in to, or taps in, your delivery apps.")
                Text("It saves offer fields and verdicts — not screen images, customer names, or customer addresses.")
                Text("Apple Maps receives only the drop-off cross-street and town, the restaurant address, town names from the map, or your position, to work out the drive back.")
                Text("During a shift it adds up miles in the background. Your route is not saved — only mile totals, and where the restaurants you arrive at are.")
                Text("Everything stays on this phone unless you export it.")
            }
        }
        .navigationTitle("Privacy")
    }
}

/// Technical details for troubleshooting: the broadcast, storage, notification tests, reader reliability, build.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var signals: ExtensionSignals
    @State private var confirmRemoveDemo = false

    private var today: [LiveOffer] { model.offers.filter { Calendar.current.isDateInToday($0.seenAt) } }

    var body: some View {
        List {
            Section("Offer reader") {
                row("Screen being captured", model.screenCaptured ? "Yes" : "No")
                row("Reader loaded", signals.loadedAt.map(time) ?? "No signal")
                row("Reader started", signals.startedAt.map(time) ?? "No signal")
                row("Frames read while open", "\(signals.frames)")
                row("Offer alerts sent", "\(signals.offers)")
                if signals.readerFailed { row("Offer reader", "Failed to load") }
                if let probe = model.probe {
                    row("Reader returns to", probe.returnDestination ?? "Not looked up yet")
                    if let code = probe.failureCode { row("Capture issue", code) }
                }
            }
            Section("Reading quality") {
                ForEach(["doordash", "uber_eats", "grubhub"], id: \.self) { platform in
                    PlatformQuality(platform: platform, offers: model.offers.filter { $0.platform == platform })
                }
                row("Offers today", "\(today.count) · \(count(.accept)) accept · \(count(.decline)) decline · \(count(.maybe)) maybe")
            }
            if let health = model.readerHealth { ReaderHealthSection(health: health) }
            Section("Notifications") {
                row("Permission", model.notificationStatus)
                row("Banners", model.bannerStatus)
                row("Scheduled Summary", model.summaryStatus)
                Button("Send a test notification") { model.sendTestNotification(after: nil) }
                Button("Test a pop-up over another app (10 s)") { model.sendTestNotification(after: 10) }
            }
            Section("Storage") {
                row("Shared App Group", model.storageAvailable ? "Available" : "Not shared with this install")
                row("Return location shared with reader", model.destinationShared ? "Yes" : "No")
                row("Offer history", OfferJournal.isShared ? "\(model.journalCount) offers" : "Inside screen reading")
            }
            Section {
                if model.hasDemoData {
                    Button("Remove demo data", role: .destructive) { confirmRemoveDemo = true }
                } else {
                    Button("Load demo data") { model.loadDemoData() }
                }
            } header: {
                Text("Demo data")
            } footer: {
                Text("Invented data to explore. Never exported.")
            }
            Section("About") {
                row("Build", (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?")
            }
        }
        .navigationTitle("Advanced & diagnostics")
        .confirmationDialog("Remove demo data?", isPresented: $confirmRemoveDemo) {
            Button("Remove demo data", role: .destructive) { model.removeDemoData() }
        }
    }

    private func count(_ verdict: Verdict) -> Int { today.filter { Verdict(notice: $0.notice) == verdict }.count }

    private func row(_ label: String, _ text: String) -> some View {
        HStack { Text(label); Spacer(); Text(text).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }
}

/// Per app: how often miles, time, and the return were found, and how fast the first notification came.
struct PlatformQuality: View {
    let platform: String
    let offers: [LiveOffer]

    var body: some View {
        if !offers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AppLogo(platform: platform, size: 20)
                    Text(Theme.appName(platform)).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(offers.count == 1 ? "1 offer" : "\(offers.count) offers").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    metric(share { $0.outboundMilliMiles != nil }, "miles read")
                    metric(share { $0.appMinutes != nil || $0.tripTimeNote != nil }, "time known")
                    metric(share { $0.returnMilliMiles != nil }, "return found")
                    metric(firstNotification, "first alert")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func share(_ test: (LiveOffer) -> Bool) -> String {
        let count = offers.filter(test).count
        return "\(Int((Double(count) / Double(offers.count) * 100).rounded()))%"
    }

    private var firstNotification: String {
        let values = offers.compactMap { $0.latencyFirstMs }.sorted()
        guard !values.isEmpty else { return "—" }
        return String(format: "%.1fs", Double(values[values.count / 2]) / 1000)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}
