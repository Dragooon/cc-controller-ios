import Foundation

final class QueuedNoteCache: @unchecked Sendable {
    private let directory: URL
    private let clock: any CCKitClock
    private let debounce: Duration
    private var pendingWrite: Task<Void, Never>?
    private let fileName = "queued-notes.json"

    init(directory: URL, clock: any CCKitClock, debounce: Duration = .milliseconds(500)) {
        self.directory = directory
        self.clock = clock
        self.debounce = debounce
    }

    static func loadSync(directory: URL, now: Date = .now) throws -> [String: [QueuedNote]]? {
        let url = directory.appendingPathComponent("queued-notes.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stored = try JSONDecoder.ccKit().decode([String: [QueuedNote]].self, from: Data(contentsOf: url))
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        return stored.reduce(into: [:]) { result, entry in
            let notes = entry.value.compactMap { note -> QueuedNote? in
                guard note.createdAt >= cutoff else { return nil }
                var note = note
                if note.state == .sending {
                    note.state = .failed(message: "The app closed before this message was sent.")
                }
                note.attachmentThumbnails = [:]
                note.useCurrentEncoding()
                return note
            }
            if !notes.isEmpty { result[entry.key] = notes }
        }
    }

    func save(_ notes: [String: [QueuedNote]]) {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(for: debounce)
                try write(notes)
            } catch is CancellationError {
            } catch {
            }
        }
    }

    func saveNow(_ notes: [String: [QueuedNote]]) {
        pendingWrite?.cancel()
        pendingWrite = nil
        try? write(notes)
    }

    func clear() {
        pendingWrite?.cancel()
        pendingWrite = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    private func write(_ notes: [String: [QueuedNote]]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persisted = notes.mapValues { $0.map { note in
            var note = note
            note.attachmentThumbnails = [:]
            return note
        } }
        let data = try JSONEncoder.ccKit().encode(persisted)
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}
