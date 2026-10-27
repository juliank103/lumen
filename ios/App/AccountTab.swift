import SwiftUI

/// Everyday settings only (user, Oct 14): rules, return location, goal and vehicle cost, notifications, location,
/// data export, privacy. Everything technical is one tap deeper in Advanced & diagnostics.
struct AccountTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var shifts = ShiftStore.shared
    @AppStorage("vehicleCostCentsPerMile") private var costPerMile = 0
    @AppStorage("keepReadingData") private var keepReadingData = true
    @AppStorage("reader2Trial") private var reader2Trial = false
    @AppStorage("trainingCapture") private var trainingCapture = false
    @State private var editingDeduction = false
    @State private var deductionText = ""
    @AppStorage(AutoSteps.enabledKey) private var autoSteps = true
    @AppStorage(AudioCues.enabledKey) private var audioCues = true
    @State private var editingGoal = false
    @ObservedObject private var goals = GoalStore.shared
    @State private var editingCost = false
    @State private var costText = ""

    private static let dayLetters = ["S", "M", "T", "W", "T", "F", "S"]

    /// The weekday bar (Oct 27): adjustable days and bar; the reader goes back to the full rules while it's busy.
    private var weekdayBar: some View {
        Section {
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { day in
                    let on = model.rules.weekdaySet.contains(day)
                    Button {
                        model.updateRules { rules in
                            var days = rules.weekdaySet
                            if on { days.remove(day) } else { days.insert(day) }
                            rules.weekdayDays = days.sorted()
                        }
                    } label: {
                        Text(Self.dayLetters[day])
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(on ? Theme.neonGreen.opacity(0.25) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(on ? Theme.neonGreen : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[day] + (on ? ", weekday bar" : ", full rules"))
                }
            }
            Stepper(value: Binding(get: { model.rules.weekdayHourly }, set: { value in model.updateRules { $0.weekdayHourlyCents = value } }),
                    in: 1000...6000, step: 50) {
                row("Hourly", model.rules.weekdayHourlyText)
            }
            Stepper(value: Binding(get: { model.rules.weekdayPerMile }, set: { value in model.updateRules { $0.weekdayCentsPerMile = value } }),
                    in: 50...300, step: 5) {
                row("Pay per mile", model.rules.weekdayPerMileText)
            }
        } header: {
            HStack {
                Text("Weekday bar")
                InfoNote(title: "Weekday bar", text: "On the marked days an offer at this bar is an Accept. 2 offers meeting your full rules within 30 minutes means it's busy: the reader goes back to your full rules, and slow-hour accepts stop.")
            }
        } footer: {
            Text(model.rules.weekdaySet.isEmpty ? "Off: your rules apply every day."
                 : "Unmarked days use your rules (\(model.rules.hourlyText), \(model.rules.perMileText)/mi).")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Stepper(value: Binding(get: { model.rules.centsPerMile },
                                           set: { value in model.updateRules { $0.centsPerMile = value } }),
                            in: 50...300, step: 5) {
                        row("Pay per mile", model.rules.perMileText + ", incl. return")
                    }
                    Stepper(value: Binding(get: { model.rules.hourlyTargetCents },
                                           set: { value in model.updateRules { $0.hourlyTargetCents = value } }),
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
                weekdayBar
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
                    Button { deductionText = MileageRate.custom.map(String.init) ?? ""; editingDeduction = true } label: {
                        row("Mileage deduction", MileageRate.custom.map { "\($0)¢ per mile" }
                            ?? "IRS rate · " + MileageRate.text(MileageRate.cents(on: Date())) + " per mile")
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
                    // Reader 2 trial (Oct 24): Apple's structured document reader runs alongside, once per offer.
                    Toggle("Reader 2 trial", isOn: $reader2Trial)
                        .onChange(of: reader2Trial) { _, on in Bridge.publish("reader2-trial", Data((on ? "on" : "off").utf8)) }
                    // Training screens (user, Oct 25): the reader saves each offer screen to Photos for the pin model.
                    Toggle("Save offer screens to Photos", isOn: $trainingCapture)
                        .onChange(of: trainingCapture) { _, on in TrainingCapture.set(on) }
                    if trainingCapture {
                        Text(TrainingCapture.permission + " · \(TrainingCapture.savedCount) saved. The reader keeps each offer screen (up to 15 DoorDash, 15 Uber and 60 Grubhub a shift) with its notification; __APP_NAME__ moves them into Photos › Recents as \"__APP_NAME__ <time> <app>\" when you open it. Open __APP_NAME__ before clearing offer notifications. Move them to the PC's pin marking tool, then delete them.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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
                TextField("Empty for the IRS rate", text: $deductionText).keyboardType(.numberPad)
                Button("Save") { MileageRate.custom = Int(deductionText).map { max(0, min(200, $0)) } }
                Button("Use the IRS rate") { MileageRate.custom = nil }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The Deduction tile on Earnings is your miles times this rate. By default it's the IRS rate for each trip's date: 70¢ in 2025, 72.5¢ for January–June 2026, 76¢ from July 1, 2026.")
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
            AIProbeSection()
            AIReviewSection()
            ReaderCompareSection()
            Section("Storage") {
                row("Shared App Group", model.storageAvailable ? "Available" : "Not shared with this install")
                // Without it, settings travel through the bridge (Oct 24); the reader confirms when it starts.
                if !model.storageAvailable {
                    row("Settings reach the reader", signals.bridgeReadAt != nil ? "Yes, through the backup channel"
                        : "Not confirmed. Start screen reading, then check again")
                }
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
        .refreshable { await model.pullRefresh() }
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

/// Diagnostics → Apple Intelligence (Oct 24 plan, step 1): is the on-device model available, how fast and how faithfully
/// does it read a test card here in the app, and does it work inside the screen reader while a delivery app is in front?
struct AIProbeSection: View {
    @EnvironmentObject private var signals: ExtensionSignals
    @State private var app: AIProbe.Result?
    @State private var reader: AIProbe.Result?
    @State private var running = false
    @State private var requested = false

    var body: some View {
        Section {
            row("On this iPhone", AIProbe.availability())
            Button(running ? "Testing…" : "Test in the app") {
                running = true
                Task {
                    let result = await AIProbe.run(calls: 3, spacing: 1, readCard: true)
                    await MainActor.run { app = result; running = false }
                }
            }
            .disabled(running)
            if let app { results(app) }
            Button("Test in the screen reader") {
                if let data = try? JSONEncoder().encode(Date()) { Bridge.publish("ai-probe-request", data) }
                requested = true
            }
            if requested && reader == nil {
                Text("Start screen reading and open DoorDash, Uber Eats or Grubhub. The test runs within a minute and takes about 2 minutes.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let reader { results(reader) }
        } header: {
            Text("Apple Intelligence")
        }
        .onAppear { reader = AIProbe.load(key: "ai-reader") }
        .onChange(of: signals.aiProbeAt) { reader = AIProbe.load(key: "ai-reader") }
    }

    @ViewBuilder private func results(_ r: AIProbe.Result) -> some View {
        row("Answered", "\(r.answered) of \(r.calls)" + (r.seconds.isEmpty ? "" : String(format: " · %.1f s each", r.seconds.reduce(0, +) / Double(r.seconds.count))))
        if let model = r.model { row("Model", model + (r.contextSize.map { " · \($0) tokens" } ?? "")) }
        if let vision = r.vision { row("Reads pictures", vision ? "Yes" : "No") }
        if let extracted = r.extracted { row("Read the test card", extracted) }
        if let grounded = r.grounded { row("Numbers match the card", grounded ? "Yes" : "No — it changed something") }
        if let image = r.imageExtracted {
            row("Read the card picture", image + (r.imageSeconds.map { String(format: " · %.1f s", $0) } ?? ""))
        }
        if let grounded = r.imageGrounded { row("Picture numbers match", grounded ? "Yes" : "No — it changed something") }
        if let error = r.firstError { Text(error).font(.caption.monospaced()).foregroundStyle(.secondary) }
        Text(r.at.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}

