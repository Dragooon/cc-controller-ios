#if DEBUG || CC_PERF
import Foundation
import Observation

@MainActor @Observable
public final class TranscriptPerformance {
    public static let shared = TranscriptPerformance()

    public private(set) var snapshot = ""
    public private(set) var groupingCount = 0

    private var sessionID = ""
    private var startedAt = Date.distantPast
    private var phases: [String: Double] = [:]
    private var responseBytes: Int?

    private init() {}

    public func begin(sessionID: String) {
        guard self.sessionID != sessionID else { return }
        reset(sessionID: sessionID)
    }

    public func beginScreenAppearance(sessionID: String) {
        reset(sessionID: sessionID)
    }

    private func reset(sessionID: String) {
        self.sessionID = sessionID
        startedAt = Date()
        phases = [:]
        responseBytes = nil
        groupingCount = 0
        snapshot = ""
    }

    public func markRequestSent() {
        mark("request_sent")
    }

    public func markResponseReceived(bytes: Int) {
        responseBytes = bytes
        mark("response_received")
    }

    public func markDecodeDone() {
        mark("decode_done")
    }

    public func markMergeDone() {
        mark("merge_done")
    }

    public func markGroupingDone() {
        groupingCount += 1
        mark("grouping_done")
    }

    public func markUsageUpdate() {
        mark("usage_update")
    }

    public func markFirstRows() {
        guard phases["first_rows"] == nil else { return }
        let elapsed = Date().timeIntervalSince(startedAt) * 1000
        #if CC_PERF
        PerfCounters.shared.recordMilliseconds(.firstRowsMilliseconds, value: elapsed)
        #endif
        mark("first_rows")
    }

    private func mark(_ phase: String) {
        guard !sessionID.isEmpty else { return }
        phases[phase] = Date().timeIntervalSince(startedAt) * 1000
        let ordered = ["request_sent", "response_received", "decode_done", "merge_done", "grouping_done", "first_rows", "usage_update"]
        let values = ordered.compactMap { phase -> String? in
            guard let value = phases[phase] else { return nil }
            return "\(phase)=\(String(format: "%.1f", value))"
        }
        let bytes = responseBytes.map { " response_bytes=\($0)" } ?? ""
        snapshot = "session=\(sessionID) \(values.joined(separator: " ")) grouping_count=\(groupingCount)\(bytes)"
        print("TRANSCRIPT_PERF \(snapshot)")
    }
}
#endif
