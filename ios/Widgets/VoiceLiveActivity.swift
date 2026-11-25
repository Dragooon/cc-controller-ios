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

/// Voice mode on the lock screen, in the Dynamic Island and in the Apple Watch Smart Stack: what it's doing, the
/// sentence in play, pause, mute and end.
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
        // A layout of its own in the Watch's Smart Stack (the lock screen view checks the family), instead of the
        // phone's shrunk to fit.
        .supplementalActivityFamilies([.small])
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
    var showsEnd = true
    var size: CGFloat = 36

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ToggleVoiceMicIntent()) {
                Image(systemName: state.isMicMuted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: size, height: size)
            }
            .accessibilityLabel(state.isMicMuted ? "Unmute the mic" : "Mute the mic")
            Button(intent: ToggleVoicePauseIntent()) {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: size, height: size)
            }
            .accessibilityLabel(state.isPaused ? "Resume voice mode" : "Pause voice mode")
            if showsEnd {
                Button(intent: EndVoiceIntent()) {
                    Image(systemName: "xmark")
                        .frame(width: size, height: size)
                }
                .accessibilityLabel("End voice mode")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(.white)
    }
}

struct VoiceActivityLockScreenView: View {
    let sessionName: String
    let state: VoiceActivityAttributes.ContentState
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            watchBody
        } else {
            phoneBody
        }
    }

    /// The Watch's Smart Stack: the phase on top, mute and pause big enough for a wrist. End stays on the phone.
    private var watchBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                VoicePhaseMark(state: state)
                Text(state.phase)
                    .font(.headline)
                    .lineLimit(1)
            }
            VoiceActivityButtons(state: state, showsEnd: false, size: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var phoneBody: some View {
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
