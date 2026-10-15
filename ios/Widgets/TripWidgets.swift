import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct TripWidgets: WidgetBundle {
    var body: some Widget { TripLiveActivity() }
}

private let purple = Color(red: 0.42, green: 0.22, blue: 0.96)

/// Lock screen and Dynamic Island for the active trip: running timer, pace, and the next step as a button.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenTrip(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false).monospacedDigit() }
                        icon: { Image(systemName: "timer") }
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.paceText).font(.headline).foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StepButtons(state: context.state)
                }
            } compactLeading: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit().frame(maxWidth: 52)
            } compactTrailing: {
                Text(context.state.paceText).foregroundStyle(.green)
            } minimal: {
                Image(systemName: "bag.fill").foregroundStyle(purple)
            }
        }
    }
}

struct LockScreenTrip: View {
    let state: TripActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                    .font(.system(.title, design: .rounded).weight(.heavy)).monospacedDigit().foregroundStyle(.white)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(state.paceText).font(.headline).foregroundStyle(.green)
                    Text("\(state.orderCount) order\(state.orderCount == 1 ? "" : "s") · \(state.payText)").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            StepButtons(state: state)
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
