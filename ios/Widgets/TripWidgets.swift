import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct TripWidgets: WidgetBundle {
    var body: some Widget { TripLiveActivity() }
}

// The app's visual language (Theme.swift, Oct 21), repeated here: the widget extension can't see the app's code.
private let purple = Color(red: 0.486, green: 0.361, blue: 1.0)
private let accept = Color(red: 0.239, green: 0.863, blue: 0.518)
private let check = Color(red: 1.0, green: 0.788, blue: 0.235)
private let decline = Color(red: 1.0, green: 0.42, blue: 0.357)
private let warn = Color(red: 1.0, green: 0.62, blue: 0.2)
private let secondary = Color(red: 0.639, green: 0.631, blue: 0.702)

private extension TripActivityAttributes.ContentState {
    var verdictColor: Color { verdict == "accept" ? accept : verdict == "decline" ? decline : check }
    var verdictIcon: String { verdict == "accept" ? "checkmark" : verdict == "decline" ? "xmark" : "minus" }
    var verdictWord: String { verdict == "accept" ? "ACCEPT" : verdict == "decline" ? "DECLINE" : "CHECK RETURN" }
}

/// The shift in the Dynamic Island and on the lock screen (user, Oct 21): an offer's verdict, "Reader off", the trip,
/// or the shift's earnings and goal.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenShift(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { ExpandedLeading(state: context.state) }
                DynamicIslandExpandedRegion(.trailing) { ExpandedTrailing(state: context.state) }
                DynamicIslandExpandedRegion(.bottom) { ExpandedBottom(state: context.state) }
            } compactLeading: {
                CompactLeading(state: context.state)
            } compactTrailing: {
                CompactTrailing(state: context.state)
            } minimal: {
                MinimalView(state: context.state)
            }
        }
    }
}

private struct CompactLeading: View {
    let state: TripActivityAttributes.ContentState
    var body: some View {
        switch state.mode {
        case "offer": Image(systemName: state.verdictIcon).font(.body.weight(.black)).foregroundStyle(state.verdictColor)
        case "readerOff": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(warn)
        case "trip": Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false).monospacedDigit().frame(maxWidth: 52)
        default: Text(state.earningsText ?? "—").fontWeight(.semibold).monospacedDigit()
        }
    }
}

private struct CompactTrailing: View {
    let state: TripActivityAttributes.ContentState
    var body: some View {
        switch state.mode {
        case "offer": Text(state.perMileText ?? state.offerPayText ?? "").fontWeight(.bold).foregroundStyle(state.verdictColor).monospacedDigit()
        case "readerOff": Text("Reader off").fontWeight(.semibold).foregroundStyle(warn)
        case "trip": Text(state.paceText).foregroundStyle(accept)
        default: Text(state.hourlyText ?? "").foregroundStyle(secondary).monospacedDigit()
        }
    }
}

private struct MinimalView: View {
    let state: TripActivityAttributes.ContentState
    var body: some View {
        switch state.mode {
        case "offer": Image(systemName: state.verdictIcon).font(.caption.weight(.black)).foregroundStyle(state.verdictColor)
        case "readerOff": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(warn)
        default: Image(systemName: "bag.fill").foregroundStyle(purple)
        }
    }
}

private struct ExpandedLeading: View {
    let state: TripActivityAttributes.ContentState
    var body: some View {
        switch state.mode {
        case "offer":
            Label(state.verdictWord, systemImage: state.verdictIcon).font(.headline.weight(.heavy)).foregroundStyle(state.verdictColor)
                .lineLimit(1).minimumScaleFactor(0.7)
        case "readerOff":
            Label("Reader off", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(warn)
        case "trip":
            Label { Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false).monospacedDigit() }
                icon: { Image(systemName: "timer") }
                .font(.headline)
        default:
            Text(state.earningsText ?? "—").font(.title2.weight(.heavy)).monospacedDigit()
        }
    }
}

private struct ExpandedTrailing: View {
    let state: TripActivityAttributes.ContentState
    var body: some View {
        switch state.mode {
        case "offer":
            if let until = state.offerUntil {
                Text(timerInterval: Date()...max(Date(), until), countsDown: true).font(.headline).monospacedDigit()
                    .foregroundStyle(secondary).frame(maxWidth: 52)
            }
        case "readerOff":
            EmptyView()
        case "trip":
            Text(state.paceText).font(.headline).foregroundStyle(accept)
        default:
            VStack(alignment: .trailing, spacing: 0) {
                Text(state.hourlyText ?? "").font(.headline).monospacedDigit()
                Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false).font(.caption).monospacedDigit()
                    .foregroundStyle(secondary).multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct ExpandedBottom: View {
    let state: TripActivityAttributes.ContentState
    var body: some View {
        switch state.mode {
        case "offer":
            OfferNumbers(state: state)
        case "readerOff":
            Text("Tap to open __APP_NAME__ and start reading.").font(.subheadline).foregroundStyle(secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case "trip":
            StepButtons(state: state)
        default:
            GoalLine(state: state)
        }
    }
}

/// $/mi and $/hr large, then pay and store.
private struct OfferNumbers: View {
    let state: TripActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(state.perMileText ?? "—").font(.system(size: 30, weight: .heavy, design: .rounded))
                Text(state.perHourText ?? "").font(.system(size: 30, weight: .heavy, design: .rounded))
                Spacer()
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text([state.offerPayText, state.offerStore].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(secondary).lineLimit(1)
        }
    }
}

/// The day's goal bar (or the shift's) and the shift's miles.
private struct GoalLine: View {
    let state: TripActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = state.goalProgress {
                ProgressView(value: min(1, max(0, progress))).tint(progress >= 1 ? accept : purple)
            }
            HStack {
                Text(state.goalText ?? "No goal set")
                Spacer()
                Text(state.milesText ?? "")
            }
            .font(.caption).foregroundStyle(secondary).monospacedDigit()
        }
    }
}

struct LockScreenShift: View {
    let state: TripActivityAttributes.ContentState
    var body: some View {
        switch state.mode {
        case "offer":
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(state.verdictWord, systemImage: state.verdictIcon).font(.headline.weight(.heavy)).foregroundStyle(state.verdictColor)
                    Spacer()
                    if let until = state.offerUntil {
                        Text(timerInterval: Date()...max(Date(), until), countsDown: true).monospacedDigit().foregroundStyle(secondary)
                            .frame(maxWidth: 52)
                    }
                }
                OfferNumbers(state: state).foregroundStyle(.white)
            }
        case "readerOff":
            Label("__APP_NAME__ stopped reading offers", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(warn)
        case "trip":
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                        .font(.system(.title, design: .rounded).weight(.heavy)).monospacedDigit().foregroundStyle(.white)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(state.paceText).font(.headline).foregroundStyle(accept)
                        Text("\(state.orderCount) order\(state.orderCount == 1 ? "" : "s") · \(state.payText)").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
                StepButtons(state: state)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.earningsText ?? "—").font(.system(.title, design: .rounded).weight(.heavy)).monospacedDigit().foregroundStyle(.white)
                    Spacer()
                    Text(state.hourlyText ?? "").font(.headline).foregroundStyle(.white).monospacedDigit()
                }
                GoalLine(state: state)
            }
        }
    }
}

struct StepButtons: View {
    let state: TripActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 8) {
            if let label = state.nextLabel, let id = state.nextActionId {
                Button(intent: TripStepIntent(actionId: id)) {
                    Text(label).font(.subheadline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
                }
                .tint(purple)
            }
            Button(intent: TripUndoIntent()) { Image(systemName: "arrow.uturn.backward") }
                .tint(.gray)
        }
    }
}
