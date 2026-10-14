import Foundation

public struct DiskCacheState: Codable, Sendable, Equatable {
    public var bootstrap: Bootstrap
    public var transcripts: [String: [TranscriptEntry]]
    public var updatedAt: Date
    var loadedLegacyFormat: Bool

    public init(bootstrap: Bootstrap, transcripts: [String: [TranscriptEntry]] = [:], updatedAt: Date) {
        self.bootstrap = bootstrap
        self.transcripts = transcripts
        self.updatedAt = updatedAt
        self.loadedLegacyFormat = false
    }

    private enum CodingKeys: String, CodingKey {
        case bootstrap
        case transcripts
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bootstrap = try container.decode(Bootstrap.self, forKey: .bootstrap)
        let rawTranscripts = try container.decodeIfPresent([String: JSONValue].self, forKey: .transcripts) ?? [:]
        transcripts = try rawTranscripts.reduce(into: [String: [TranscriptEntry]]()) { result, item in
            let data = try JSONEncoder.ccKit().encode(item.value)
            result[item.key] = try decodeTranscriptEntries(from: data, sessionID: item.key)
        }
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        loadedLegacyFormat = container.contains(.transcripts)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bootstrap, forKey: .bootstrap)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public actor DiskCache {
    private let directory: URL
    private let clock: any CCKitClock
    let debounce: Duration
    private var pendingWrite: Task<Void, Never>?
    private let stateFileName = "state.json"
    private let transcriptPrefix = "transcript-"
    private let transcriptSuffix = ".json"

    public init(directory: URL, clock: any CCKitClock = SystemCCKitClock(), debounce: Duration = .seconds(30)) {
        self.directory = directory
        self.clock = clock
        self.debounce = debounce
    }

    public func load() throws -> DiskCacheState? {
        let stateURL = directory.appendingPathComponent(stateFileName)
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let stateData = try Data(contentsOf: stateURL)
        var state = try JSONDecoder.ccKit().decode(DiskCacheState.self, from: stateData)
        for url in transcriptURLs() {
            guard let key = transcriptKey(for: url),
                  let data = try? Data(contentsOf: url),
                  let entries = try? decodeTranscriptEntries(from: data, sessionID: key) else { continue }
            state.transcripts[key] = entries
        }
        return state
    }

    public func save(
        _ state: DiskCacheState,
        changedTranscripts: [String: [TranscriptEntry]]? = nil,
        retainedTranscriptKeys: Set<String>? = nil
    ) {
        let changedTranscripts = changedTranscripts ?? state.transcripts
        let retainedTranscriptKeys = retainedTranscriptKeys ?? Set(state.transcripts.keys)
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: self.debounce)
                try await self.write(
                    state,
                    changedTranscripts: changedTranscripts,
                    retainedTranscriptKeys: retainedTranscriptKeys
                )
            } catch is CancellationError {
            } catch {
            }
        }
    }

    public func saveNow(
        _ state: DiskCacheState,
        changedTranscripts: [String: [TranscriptEntry]]? = nil,
        retainedTranscriptKeys: Set<String>? = nil
    ) {
        let changedTranscripts = changedTranscripts ?? state.transcripts
        let retainedTranscriptKeys = retainedTranscriptKeys ?? Set(state.transcripts.keys)
        pendingWrite?.cancel()
        pendingWrite = nil
        do {
            try write(
                state,
                changedTranscripts: changedTranscripts,
                retainedTranscriptKeys: retainedTranscriptKeys
            )
        } catch {
        }
    }

    public func flush() async {
        await pendingWrite?.value
        pendingWrite = nil
    }

    public func clear() throws {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func transcriptFileURL(for key: String) -> URL {
        directory.appendingPathComponent(transcriptFileName(for: key))
    }

    private func write(
        _ state: DiskCacheState,
        changedTranscripts: [String: [TranscriptEntry]],
        retainedTranscriptKeys: Set<String>
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateData = try JSONEncoder.ccKit().encode(state)
        let stateURL = directory.appendingPathComponent(stateFileName)
        try stateData.write(to: stateURL, options: .atomic)
        try protect(stateURL)

        for (key, entries) in changedTranscripts {
            let data = try JSONEncoder.ccKit().encode(Array(entries.suffix(400)))
            let url = transcriptFileURL(for: key)
            try data.write(to: url, options: .atomic)
            try protect(url)
        }

        for url in transcriptURLs() {
            guard let key = transcriptKey(for: url), !retainedTranscriptKeys.contains(key) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func protect(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }

    private func transcriptURLs() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix(transcriptPrefix) && name.hasSuffix(transcriptSuffix)
        }
    }

    private func transcriptFileName(for key: String) -> String {
        let encoded = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(transcriptPrefix)\(encoded)\(transcriptSuffix)"
    }

    private func transcriptKey(for url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix(transcriptPrefix) else { return nil }
        var encoded = String(name.dropFirst(transcriptPrefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
