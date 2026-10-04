import Foundation

public struct DiskCacheState: Codable, Sendable, Equatable {
    public var bootstrap: Bootstrap
    public var transcripts: [String: [TranscriptEntry]]
    public var updatedAt: Date

    public init(bootstrap: Bootstrap, transcripts: [String: [TranscriptEntry]] = [:], updatedAt: Date) {
        self.bootstrap = bootstrap
        self.transcripts = transcripts
        self.updatedAt = updatedAt
    }
}

public actor DiskCache {
    private let directory: URL
    private let clock: any CCKitClock
    let debounce: Duration
    private var pendingWrite: Task<Void, Never>?
    private let fileName = "state.json"

    public init(directory: URL, clock: any CCKitClock = SystemCCKitClock(), debounce: Duration = .seconds(5)) {
        self.directory = directory
        self.clock = clock
        self.debounce = debounce
    }

    public func load() throws -> DiskCacheState? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.ccKit().decode(DiskCacheState.self, from: data)
    }

    public func save(_ state: DiskCacheState) {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: self.debounce)
                try await self.write(state)
            } catch is CancellationError {
            } catch {
            }
        }
    }

    public func saveNow(_ state: DiskCacheState) {
        pendingWrite?.cancel()
        pendingWrite = nil
        do {
            try write(state)
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
        let url = directory.appendingPathComponent(fileName)
        try FileManager.default.removeItem(at: url)
    }

    private func write(_ state: DiskCacheState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.ccKit().encode(state)
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}
