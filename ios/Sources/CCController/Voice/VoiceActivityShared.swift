import ActivityKit
import AppIntents
import Foundation

// Compiled into the app and the widget extension. The widget draws the Live Activity from these attributes; its
// buttons run these intents, which the system performs in the app's process, where the handlers are registered.

/// The voice-mode Live Activity: which session is talking, and what voice mode is doing right now.
public struct VoiceActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// The strip's status, e.g. "Listening" or "Speaking".
        public var phase: String
        /// SF Symbol for the phase.
        public var symbol: String
        /// The sentence being spoken, or what was heard, or empty.
        public var line: String
        public var isPaused: Bool

        public init(phase: String, symbol: String, line: String, isPaused: Bool) {
            self.phase = phase
            self.symbol = symbol
            self.line = line
            self.isPaused = isPaused
        }
    }

    public var sessionName: String

    public init(sessionName: String) {
        self.sessionName = sessionName
    }
}

/// What the Live Activity's buttons do. Only the app sets these; in the widget extension they stay empty.
@MainActor
public enum VoiceActivityActions {
    public static var togglePause: (() -> Void)?
    public static var end: (() -> Void)?
}

/// Pauses voice mode (reply held, mic muted) or resumes it.
public struct ToggleVoicePauseIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Pause or resume voice mode"

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run { VoiceActivityActions.togglePause?() }
        return .result()
    }
}

/// Ends voice mode.
public struct EndVoiceIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "End voice mode"

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run { VoiceActivityActions.end?() }
        return .result()
    }
}
