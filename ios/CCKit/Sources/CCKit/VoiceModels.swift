import Foundation

/// What a host's voice routes can do (`GET /api/voice`). Voice mode needs both engines.
public struct VoiceCapabilities: Codable, Sendable, Equatable {
    public struct Engine: Codable, Sendable, Equatable {
        public var available: Bool
        public var model: String?
        public var voice: String?
        public var voices: [String]

        public init(available: Bool, model: String? = nil, voice: String? = nil, voices: [String] = []) {
            self.available = available
            self.model = model
            self.voice = voice
            self.voices = voices
        }

        private enum CodingKeys: String, CodingKey { case available, model, voice, voices }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
            model = try container.decodeIfPresent(String.self, forKey: .model)
            voice = try container.decodeIfPresent(String.self, forKey: .voice)
            voices = try container.decodeIfPresent([String].self, forKey: .voices) ?? []
        }
    }

    public var stt: Engine
    public var tts: Engine

    public init(stt: Engine, tts: Engine) {
        self.stt = stt
        self.tts = tts
    }

    private enum CodingKeys: String, CodingKey { case stt, tts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stt = try container.decodeIfPresent(Engine.self, forKey: .stt) ?? Engine(available: false)
        tts = try container.decodeIfPresent(Engine.self, forKey: .tts) ?? Engine(available: false)
    }

    /// Voice mode needs the host to both hear and speak.
    public var isAvailable: Bool { stt.available && tts.available }
}

/// One clip's text from `POST /api/voice/transcribe`. An empty `text` means the clip held no speech.
public struct VoiceTranscription: Codable, Sendable, Equatable {
    public var text: String
    public var model: String?
    public var durationMs: Int?
    public var elapsedMs: Int?

    public init(text: String, model: String? = nil, durationMs: Int? = nil, elapsedMs: Int? = nil) {
        self.text = text
        self.model = model
        self.durationMs = durationMs
        self.elapsedMs = elapsedMs
    }

    private enum CodingKeys: String, CodingKey { case text, model, durationMs, elapsedMs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = (try container.decodeIfPresent(String.self, forKey: .text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        elapsedMs = try container.decodeIfPresent(Int.self, forKey: .elapsedMs)
    }
}

public struct SessionVoiceResult: Codable, Sendable, Equatable {
    public var voice: Bool
    public init(voice: Bool) { self.voice = voice }
}

/// The audio `POST /api/voice/speech` streams back: 16-bit little-endian mono PCM at 24 kHz.
public enum VoiceSpeechFormat {
    public static let sampleRate: Double = 24_000
    public static let channels = 1
    public static let bytesPerSample = 2

    /// How long a block of the host's PCM plays for.
    public static func duration(ofBytes count: Int) -> TimeInterval {
        Double(count / bytesPerSample) / sampleRate
    }
}

/// Something the agent put on the phone's screen with `show_on_phone`. The controller sends it as a transcript
/// entry of kind `stage`; it decodes as `.unknown(kind: "stage", ...)` and is read through `TranscriptEntry.stage`.
public struct StageEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        case markdown(String)
        case image(url: String)
    }

    public var id: String
    public var ts: Date?
    public var title: String
    public var content: Content
    /// `running` until the tool call's result arrives, then `done` or `error`. Only a done entry is shown; an image
    /// gets its URL with the result. Absent means done.
    public var state: String?
    public var error: String?

    public init(id: String, ts: Date? = nil, title: String, content: Content, state: String? = nil, error: String? = nil) {
        self.id = id
        self.ts = ts
        self.title = title
        self.content = content
        self.state = state
        self.error = error
    }

    /// Whether the entry is ready to show.
    public var isDone: Bool { state == nil || state == "done" }

    private enum CodingKeys: String, CodingKey { case id, ts, title, text, markdown, imageUrl, state, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ts = try container.decodeIfPresent(Date.self, forKey: .ts)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? container.decodeIfPresent(String.self, forKey: .text) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        if let imageURL = try container.decodeIfPresent(String.self, forKey: .imageUrl), !imageURL.isEmpty {
            content = .image(url: imageURL)
        } else {
            content = .markdown(try container.decodeIfPresent(String.self, forKey: .markdown) ?? "")
        }
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id)
        id = decodedID ?? "stage-\(Int(ts?.timeIntervalSince1970 ?? 0))-\(title)"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(ts, forKey: .ts)
        try container.encode(title, forKey: .title)
        switch content {
        case .markdown(let text): try container.encode(text, forKey: .markdown)
        case .image(let url): try container.encode(url, forKey: .imageUrl)
        }
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(error, forKey: .error)
    }

    /// The served file's session and name, for an image the controller stored under `/api/files/<session>/<name>`.
    public var imageFile: (sessionID: String, name: String)? {
        guard case .image(let url) = content else { return nil }
        let path = URLComponents(string: url)?.path ?? url
        let parts = path.split(separator: "/").map(String.init)
        guard let filesIndex = parts.firstIndex(of: "files"), parts.count >= filesIndex + 3 else { return nil }
        let session = parts[filesIndex + 1].removingPercentEncoding ?? parts[filesIndex + 1]
        let name = parts[(filesIndex + 2)...].joined(separator: "/").removingPercentEncoding ?? parts[filesIndex + 2]
        return (session, name)
    }
}

public extension TranscriptEntry {
    /// The stage content when this entry is a `show_on_phone` call the controller turned into a `stage` entry.
    var stage: StageEntry? {
        guard case .unknown(let kind, let raw) = self, kind == "stage" else { return nil }
        guard let data = try? JSONEncoder.ccKit().encode(raw) else { return nil }
        return try? JSONDecoder.ccKit().decode(StageEntry.self, from: data)
    }
}
