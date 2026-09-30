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
    private var pendingWrite: Task<Void, Never>?
    private let fileName = "state.json"

    public init(directory: URL, clock: any CCKitClock = SystemCCKitClock()) {
        self.directory = directory
        self.clock = clock
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
                try await self.clock.sleep(for: .seconds(1))
                try await self.write(state)
            } catch is CancellationError {
            } catch {
            }
        }
    }

    public func flush() async {
        await pendingWrite?.value
        pendingWrite = nil
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
