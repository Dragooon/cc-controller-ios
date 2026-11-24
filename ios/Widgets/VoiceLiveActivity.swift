import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct CCControllerWidgets: WidgetBundle {
    var body: some Widget {
        VoiceLiveActivity()
    }
}

/// Voice mode on the lock screen and in the Dynamic Island: what it's doing, the sentence in play, pause and end.
struct VoiceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            VoiceActivityLockScreenView(sessionName: context.attributes.sessionName, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VoicePhaseMark(state: context.state)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.phase)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VoiceActivityButtons(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.line.isEmpty ? context.attributes.sessionName : context.state.line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                VoicePhaseMark(state: context.state)
            } compactTrailing: {
                Text(context.state.phase)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 64)
            } minimal: {
                VoicePhaseMark(state: context.state)
            }
            .keylineTint(VoiceActivityStyle.accent)
        }
    }
}

enum VoiceActivityStyle {
    /// The app's accent.
    static let accent = Color(red: 0.89, green: 0.49, blue: 0.36)
}

struct VoicePhaseMark: View {
    let state: VoiceActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.isPaused ? Color.secondary : VoiceActivityStyle.accent)
            .accessibilityLabel(state.phase)
    }
}

struct VoiceActivityButtons: View {
    let state: VoiceActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ToggleVoicePauseIntent()) {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(state.isPaused ? "Resume voice mode" : "Pause voice mode")
            Button(intent: EndVoiceIntent()) {
                Image(systemName: "xmark")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("End voice mode")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(.white)
    }
}

struct VoiceActivityLockScreenView: View {
    let sessionName: String
    let state: VoiceActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            VoicePhaseMark(state: state)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.phase)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(state.line.isEmpty ? sessionName : state.line)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VoiceActivityButtons(state: state)
        }
        .padding(16)
    }
}
