import Foundation

public struct TranscriptCacheFile: Codable, Sendable, Equatable {
    /// Bumped when a daemon's entry ids change meaning, so a cached copy can't merge into a fresh
    /// page as duplicates. 3: a queued prompt's id comes from its enqueue record.
    static let currentVersion = 3

    public let v: Int
    public var entries: [TranscriptEntry]
    public var rev: Int?
    public var epoch: String?

    public init(entries: [TranscriptEntry], rev: Int? = nil, epoch: String? = nil) {
        self.v = Self.currentVersion
        self.entries = entries
        self.rev = rev
        self.epoch = epoch
    }

    private enum CodingKeys: String, CodingKey { case v, entries, rev, epoch }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
        entries = try decodeTranscriptEntries(from: container.superDecoder(forKey: .entries), sessionID: decoder.userInfo[.transcriptSessionID] as? String)
        rev = try container.decodeIfPresent(Int.self, forKey: .rev)
        epoch = try container.decodeIfPresent(String.self, forKey: .epoch)
    }
}

public struct TranscriptCacheMetadata: Codable, Sendable, Equatable {
    public var rev: Int?
    public var epoch: String?

    public init(rev: Int? = nil, epoch: String? = nil) {
        self.rev = rev
        self.epoch = epoch
    }
}

public struct DiskCacheState: Codable, Sendable, Equatable {
    public var bootstrap: Bootstrap
    public var transcripts: [String: [TranscriptEntry]]
    public var updatedAt: Date
    public var transcriptMetadata: [String: TranscriptCacheMetadata]
    var loadedLegacyFormat: Bool

    public init(bootstrap: Bootstrap, transcripts: [String: [TranscriptEntry]] = [:], updatedAt: Date, transcriptMetadata: [String: TranscriptCacheMetadata] = [:]) {
        self.bootstrap = bootstrap
        self.transcripts = transcripts
        self.updatedAt = updatedAt
        self.transcriptMetadata = transcriptMetadata
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
        do {
            transcripts = try container.decodeIfPresent([String: [TranscriptEntry]].self, forKey: .transcripts) ?? [:]
        } catch {
            let rawTranscripts = try container.decodeIfPresent([String: JSONValue].self, forKey: .transcripts) ?? [:]
            transcripts = try rawTranscripts.reduce(into: [String: [TranscriptEntry]]()) { result, item in
                let data = try JSONEncoder.ccKit().encode(item.value)
                result[item.key] = try decodeTranscriptEntries(from: data, sessionID: item.key)
            }
        }
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        transcriptMetadata = [:]
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
            guard let key = transcriptKey(for: url), let data = try? Data(contentsOf: url) else { continue }
            guard let file = try? JSONDecoder.ccKit().decode(TranscriptCacheFile.self, from: data),
                  file.v == TranscriptCacheFile.currentVersion else { continue }
            state.transcripts[key] = file.entries
            state.transcriptMetadata[key] = TranscriptCacheMetadata(rev: file.rev, epoch: file.epoch)
        }
        return state
    }

    public func save(
        _ state: DiskCacheState,
        changedTranscripts: [String: [TranscriptEntry]]? = nil,
        changedTranscriptMetadata: [String: TranscriptCacheMetadata]? = nil,
        retainedTranscriptKeys: Set<String>? = nil
    ) {
        let changedTranscripts = changedTranscripts ?? state.transcripts
        let changedTranscriptMetadata = changedTranscriptMetadata ?? state.transcriptMetadata
        let retainedTranscriptKeys = retainedTranscriptKeys ?? Set(state.transcripts.keys)
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: self.debounce)
                try await self.write(
                    state,
                    changedTranscripts: changedTranscripts,
                    changedTranscriptMetadata: changedTranscriptMetadata,
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
        changedTranscriptMetadata: [String: TranscriptCacheMetadata]? = nil,
        retainedTranscriptKeys: Set<String>? = nil
    ) {
        let changedTranscripts = changedTranscripts ?? state.transcripts
        let changedTranscriptMetadata = changedTranscriptMetadata ?? state.transcriptMetadata
        let retainedTranscriptKeys = retainedTranscriptKeys ?? Set(state.transcripts.keys)
        pendingWrite?.cancel()
        pendingWrite = nil
        do {
            try write(
                state,
                changedTranscripts: changedTranscripts,
                changedTranscriptMetadata: changedTranscriptMetadata,
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
        changedTranscriptMetadata: [String: TranscriptCacheMetadata],
        retainedTranscriptKeys: Set<String>
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateData = try JSONEncoder.ccKit().encode(state)
        let stateURL = directory.appendingPathComponent(stateFileName)
        try stateData.write(to: stateURL, options: .atomic)
        try protect(stateURL)

        for (key, entries) in changedTranscripts {
            let metadata = changedTranscriptMetadata[key] ?? TranscriptCacheMetadata()
            let file = TranscriptCacheFile(
                entries: Array(entries.suffix(400)),
                rev: metadata.rev,
                epoch: metadata.epoch
            )
            let data = try JSONEncoder.ccKit().encode(file)
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
