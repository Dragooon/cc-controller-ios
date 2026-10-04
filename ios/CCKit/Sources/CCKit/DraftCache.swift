import Foundation

final class DraftCache: @unchecked Sendable {
    private let directory: URL
    private let clock: any CCKitClock
    private let debounce: Duration
    private var pendingWrite: Task<Void, Never>?
    private let fileName = "drafts.json"

    init(directory: URL, clock: any CCKitClock, debounce: Duration = .milliseconds(500)) {
        self.directory = directory
        self.clock = clock
        self.debounce = debounce
    }

    static func loadSync(directory: URL) throws -> [String: String]? {
        let url = directory.appendingPathComponent("drafts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    func save(_ drafts: [String: String]) {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(for: debounce)
                try write(drafts)
            } catch is CancellationError {
            } catch {
            }
        }
    }

    func saveNow(_ drafts: [String: String]) {
        pendingWrite?.cancel()
        pendingWrite = nil
        try? write(drafts)
    }

    func clear() {
        pendingWrite?.cancel()
        pendingWrite = nil
        let url = directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ drafts: [String: String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(drafts)
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}
