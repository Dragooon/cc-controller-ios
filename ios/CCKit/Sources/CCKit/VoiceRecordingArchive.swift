import Foundation
import Observation

/// One utterance you spoke in voice mode, kept on the phone in the format the mic gave it, so it can be played back
/// or transcribed again later (possibly by another model).
public struct VoiceRecording: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var controllerID: String
    public var sessionID: String
    public var createdAt: Date
    public var durationMs: Int
    public var fileName: String
    public var mimeType: String
    /// What the host heard. Nil until it answers.
    public var transcript: String?
    public var model: String?
    /// The message this utterance went into, once its turn was sent.
    public var turnText: String?
    /// Heard while a reply played and taken for the reply's own echo; not sent.
    public var echo: Bool

    public init(id: String, controllerID: String, sessionID: String, createdAt: Date, durationMs: Int, fileName: String, mimeType: String, transcript: String? = nil, model: String? = nil, turnText: String? = nil, echo: Bool = false) {
        self.id = id
        self.controllerID = controllerID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.fileName = fileName
        self.mimeType = mimeType
        self.transcript = transcript
        self.model = model
        self.turnText = turnText
        self.echo = echo
    }
}

/// The phone's archive of every voice-mode utterance: the audio files plus an index. Nothing here leaves the phone
/// except a clip's upload for transcription.
@MainActor @Observable
public final class VoiceRecordingArchive {
    public private(set) var recordings: [VoiceRecording] = []
    public let directory: URL
    private let indexURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let stored = try? JSONDecoder.ccKit().decode([VoiceRecording].self, from: data) {
            recordings = stored
        }
    }

    /// The app's archive under Application Support, kept out of iCloud backups.
    public static func standardDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var url = base.appendingPathComponent("VoiceRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    public func fileURL(for recording: VoiceRecording) -> URL {
        directory.appendingPathComponent(recording.fileName)
    }

    /// Moves a finished clip into the archive and records it.
    @discardableResult
    public func add(_ recording: VoiceRecording, movingFileAt source: URL) throws -> VoiceRecording {
        let destination = fileURL(for: recording)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        recordings.append(recording)
        save()
        return recording
    }

    public func update(id: String, _ change: (inout VoiceRecording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        change(&recordings[index])
        save()
    }

    /// Notes which message a set of utterances became.
    public func markTurn(ids: [String], text: String) {
        let wanted = Set(ids)
        var changed = false
        for index in recordings.indices where wanted.contains(recordings[index].id) {
            recordings[index].turnText = text
            changed = true
        }
        if changed { save() }
    }

    public func recordings(controllerID: String, sessionID: String) -> [VoiceRecording] {
        recordings.filter { $0.controllerID == controllerID && $0.sessionID == sessionID }
    }

    /// The utterances behind one sent message, matched by its text.
    public func recordings(controllerID: String, sessionID: String, turnText: String) -> [VoiceRecording] {
        let wanted = turnText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        return recordings(controllerID: controllerID, sessionID: sessionID).filter {
            $0.turnText?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }
    }

    /// Bytes the archive's audio takes.
    public func totalBytes() -> Int64 {
        recordings.reduce(Int64(0)) { total, recording in
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL(for: recording).path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    public func allFileURLs() -> [URL] {
        recordings.map(fileURL(for:)).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func deleteAll() {
        for recording in recordings {
            try? FileManager.default.removeItem(at: fileURL(for: recording))
        }
        recordings = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder.ccKit().encode(recordings) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
