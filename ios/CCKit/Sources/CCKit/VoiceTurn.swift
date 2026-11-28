import Foundation

/// Decides when your spoken turn is complete. The phone cuts your speech into utterances at each pause; a turn is
/// sent once an utterance ends on a finished thought. One that trails off ("…and", "…so") holds the turn open a
/// few seconds for the rest (walkie-talkie's rule). Punctuation from the recogniser is ignored: it adds a full
/// stop to fragments.
public struct VoiceTurnPolicy: Sendable, Equatable {
    /// How long a trailing utterance holds the turn open for more.
    public var holdAfterTrailingWord: TimeInterval
    /// The longest a turn is held open in total, however you trail off.
    public var maximumHold: TimeInterval
    /// How long after your last words a finished thought waits before it's sent, counted from when the phone stopped
    /// hearing you. People pause mid-thought; at once, it sent half a thought (Shitiz: "naturally I pause a bit while
    /// speaking").
    public var pauseBeforeSend: TimeInterval

    public init(holdAfterTrailingWord: TimeInterval = 3, maximumHold: TimeInterval = 8, pauseBeforeSend: TimeInterval = 2) {
        self.holdAfterTrailingWord = holdAfterTrailingWord
        self.maximumHold = maximumHold
        self.pauseBeforeSend = pauseBeforeSend
    }

    public static let trailingWords: Set<String> = [
        "and", "or", "but", "so", "then", "because", "cause", "to", "the", "a", "an", "of", "with", "for", "in", "on",
        "at", "from", "into", "if", "that", "which", "who", "when", "while", "like", "um", "uh", "er", "erm", "also",
        "plus", "maybe", "and then", "i", "we", "it's", "is", "are", "was", "my", "your", "our",
    ]

    /// Whether the text stops mid-thought.
    public func endsMidThought(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix(",") || trimmed.hasSuffix("…") || trimmed.hasSuffix("...") || trimmed.hasSuffix("-") { return true }
        let words = VoiceWords.normalized(trimmed)
        guard let last = words.last else { return false }
        if Self.trailingWords.contains(last) { return true }
        if words.count >= 2, Self.trailingWords.contains(words[words.count - 2] + " " + last) { return true }
        return false
    }

    public enum Decision: Sendable, Equatable {
        /// Send the turn now.
        case send
        /// Keep listening; send at this time unless more speech arrives.
        case hold(until: Date)
        /// More speech is on its way (you're talking again, or an utterance is still being transcribed).
        case wait
    }

    /// - Parameters:
    ///   - text: the turn so far, all its utterances joined.
    ///   - speaking: the phone hears you talking right now.
    ///   - transcribing: an utterance of this turn is still with the host.
    ///   - turnStartedAt: when the turn's first utterance ended.
    ///   - speechEndedAt: when its latest utterance ended; nil counts from now.
    public func decide(text: String, speaking: Bool, transcribing: Bool, turnStartedAt: Date, now: Date, speechEndedAt: Date? = nil) -> Decision {
        if transcribing { return .wait }
        if speaking && now.timeIntervalSince(turnStartedAt) < maximumHold { return .wait }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .wait }
        let latest = turnStartedAt.addingTimeInterval(maximumHold)
        let ready = endsMidThought(text)
            ? now.addingTimeInterval(holdAfterTrailingWord)
            : (speechEndedAt ?? now).addingTimeInterval(pauseBeforeSend)
        let until = min(ready, latest)
        return until <= now ? .send : .hold(until: until)
    }

    /// Joins a turn's utterances in order.
    public static func join(_ utterances: [String]) -> String {
        utterances
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Recognises a clip that holds only a hesitation sound. Steady room noise (an air conditioner, a fan) that gets past
/// the level gate comes back from the recogniser as "Hmm." or "Uh.", and a turn of nothing but those is noise.
public enum VoiceFiller {
    public static let sounds: Set<String> = [
        "ah", "ahh", "eh", "er", "erm", "hm", "hmm", "hmmm", "huh", "mm", "mmm", "mhm", "oh", "uh", "uhh", "uhm", "um", "umm",
    ]

    /// True when every word heard is a hesitation sound (or nothing was heard).
    public static func isFillerOnly(_ text: String) -> Bool {
        VoiceWords.normalized(text).allSatisfy { sounds.contains($0) }
    }
}

/// Recognises the phone hearing its own voice. Echo cancellation leaves some of the reply in the mic, so speech
/// heard while a reply plays only interrupts once it holds words the reply doesn't (walkie-talkie and Session Kit
/// do the same).
public enum VoiceEcho {
    /// Words of yours a reply must not contain before talking over it cuts the reply.
    public static let bargeInWordCount = 2

    /// How many of the heard words are not in what was being spoken.
    public static func newWords(heard: String, spoken: String) -> Int {
        let spokenWords = Set(VoiceWords.normalized(spoken))
        return VoiceWords.normalized(heard).filter { !spokenWords.contains($0) }.count
    }

    /// Whether speech heard during a reply is you, rather than the reply leaking back into the mic.
    public static func isBargeIn(heard: String, spoken: String) -> Bool {
        newWords(heard: heard, spoken: spoken) >= bargeInWordCount
    }

    /// Whether the heard text is just the reply coming back: most of its words are the reply's.
    public static func isEcho(heard: String, spoken: String) -> Bool {
        let heardWords = VoiceWords.normalized(heard)
        guard !heardWords.isEmpty else { return true }
        let spokenWords = Set(VoiceWords.normalized(spoken))
        guard !spokenWords.isEmpty else { return false }
        let matching = heardWords.filter { spokenWords.contains($0) }.count
        return Double(matching) / Double(heardWords.count) >= 0.6 && newWords(heard: heard, spoken: spoken) < bargeInWordCount
    }
}

enum VoiceWords {
    /// Lowercased words with punctuation removed ("Don't," → "don't").
    static func normalized(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { word in
                String(word.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "’" })
                    .replacingOccurrences(of: "’", with: "'")
            }
            .filter { !$0.isEmpty }
    }
}

/// What voice mode does with each new transcript entry while it's on.
public enum VoiceReplyEvent: Sendable, Equatable {
    /// An assistant text block to read aloud.
    case speak(entryID: String, text: String)
    /// The agent answered "(skip)": nothing to say.
    case skip(entryID: String)
    /// The agent's turn ended.
    case turnEnded(entryID: String)
    /// The agent put something on the screen.
    case stage(StageEntry)
}

/// Picks the entries voice mode reacts to. Everything already in the transcript when voice mode turned on counts as
/// heard, so turning it on never reads out the past.
public struct VoiceReplyTracker: Sendable {
    private var seen: Set<String>

    public init(baseline entries: [TranscriptEntry]) {
        seen = Set(entries.map(Self.key(for:)))
    }

    public mutating func events(in entries: [TranscriptEntry]) -> [VoiceReplyEvent] {
        var events: [VoiceReplyEvent] = []
        for entry in entries {
            let key = Self.key(for: entry)
            guard !seen.contains(key) else { continue }
            switch entry {
            case .assistant(let assistant):
                let text = assistant.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // An empty block (a tool-only message) isn't final text; leave it unseen in case text arrives.
                guard !text.isEmpty else { continue }
                seen.insert(key)
                events.append(SpeakableText.isSkip(text) ? .skip(entryID: key) : .speak(entryID: key, text: text))
            case .turnEnd:
                seen.insert(key)
                events.append(.turnEnded(entryID: key))
            default:
                if let stage = entry.stage {
                    // A stage entry is replaced in place when its tool call finishes; wait for that.
                    guard stage.state != "running" else { continue }
                    seen.insert(key)
                    if stage.isDone { events.append(.stage(stage)) }
                } else {
                    seen.insert(key)
                }
            }
        }
        return events
    }

    static func key(for entry: TranscriptEntry) -> String {
        if let id = entry.id, !id.isEmpty { return "\(entry.kind):\(id)" }
        let stamp = entry.ts.map { String($0.timeIntervalSince1970) } ?? ""
        return "\(entry.kind):\(stamp):\(entry.text ?? "")"
    }
}
