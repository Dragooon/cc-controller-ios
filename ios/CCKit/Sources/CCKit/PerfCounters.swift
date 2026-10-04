#if CC_PERF
import Foundation

public final class PerfCounters: @unchecked Sendable {
    public enum Counter: String, CaseIterable, Sendable {
        case transcriptList
        case turnRow
        case transcriptRow
        case composerBody
        case bottomStackBody
        case markdownView
        case liveClock
        case activityFooter
        case sessionHeader
        case markdownParse
        case markdownCacheHit
        case markdownCacheMiss
        case refreshTurns
        case scrollToBottom
        case scheduleCacheWrite
        case bootstrapAndReconcile
        case refetchTail
        case refetchGap
        case sseState
        case sseStateDelta
        case sseTranscript
        case sseRegistry
        case sseUsage
        case sseSubagents
        case stateDeltaApplyMilliseconds
        case subagentsApplyMilliseconds
        case transcriptApplyMilliseconds
        case mainActorBusyMilliseconds
    }

    public static let shared = PerfCounters()

    private let lock = NSLock()
    private let startedAt = Date()
    private var counts: [String: Int] = [:]
    private var values: [String: [Int]] = [:]
    private var durationTotals: [String: Double] = [:]
    private var timer: DispatchSourceTimer?

    private init() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
        timer.setEventHandler { [weak self] in self?.dump() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    @discardableResult
    public func hit(_ counter: Counter) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let key = counter.rawValue
        counts[key, default: 0] += 1
        return counts[key] ?? 0
    }

    public func record(_ counter: Counter, value: Int) {
        _ = hit(counter)
        lock.lock()
        values[counter.rawValue, default: []].append(value)
        lock.unlock()
    }

    public func recordMilliseconds(_ counter: Counter, value: Double) {
        _ = hit(counter)
        lock.lock()
        durationTotals[counter.rawValue, default: 0] += max(0, value)
        lock.unlock()
    }

    public func dump() {
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        lock.lock()
        let snapshot = counts
        let valueSnapshot = values
        let durationSnapshot = durationTotals
        lock.unlock()
        let rates = Dictionary(uniqueKeysWithValues: Counter.allCases.map { counter in
            (counter.rawValue, (Double(snapshot[counter.rawValue] ?? 0) / elapsed))
        })
        let durationRates = durationSnapshot.mapValues { $0 / elapsed }
        let payload: [String: Any] = [
            "scenario": ProcessInfo.processInfo.environment["CC_PERF_SCENARIO"] ?? "unknown",
            "elapsed_seconds": elapsed,
            "counts": snapshot,
            "per_second": rates,
            "values": valueSnapshot,
            "duration_ms_total": durationSnapshot,
            "duration_ms_per_second": durationRates,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let path = library.appendingPathComponent("cc-perf.json")
        try? data.write(to: path, options: .atomic)
    }
}
#endif
