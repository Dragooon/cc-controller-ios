import Foundation

/// The goal a session works toward (Claude Code's `/goal`), as the controller reports it on the session while one is
/// set. Claude keeps working until a check finds the condition met, or someone clears it.
public struct SessionGoal: Codable, Sendable, Equatable {
    public var condition: String
    /// When it was set; nil when the controller only saw later checks of it.
    public var since: Date?
    /// How many checks have found it not yet met.
    public var checks: Int?
    /// What the latest of those checks said was still missing.
    public var lastReason: String?

    public init(condition: String, since: Date? = nil, checks: Int? = nil, lastReason: String? = nil) {
        self.condition = condition
        self.since = since
        self.checks = checks
        self.lastReason = lastReason
    }
}

/// A transcript entry of kind `goal`: a goal was set, checked and found not met, met, failed, or cleared. Older
/// controllers never send it; it decodes as `.unknown(kind: "goal", ...)` and is read through `TranscriptEntry.goal`.
public struct GoalEntry: Codable, Sendable, Equatable {
    public var id: String?
    public var rev: Int?
    public var ts: Date?
    /// set, checked, met, failed or cleared.
    public var status: String?
    public var condition: String?
    public var reason: String?
    public var iterations: Int?
    public var durationMs: Int?

    public init(id: String? = nil, rev: Int? = nil, ts: Date? = nil, status: String? = nil, condition: String? = nil, reason: String? = nil, iterations: Int? = nil, durationMs: Int? = nil) {
        self.id = id
        self.rev = rev
        self.ts = ts
        self.status = status
        self.condition = condition
        self.reason = reason
        self.iterations = iterations
        self.durationMs = durationMs
    }
}

public extension TranscriptEntry {
    /// The goal event when this entry is one.
    var goal: GoalEntry? {
        guard case .unknown(let kind, let raw) = self, kind == "goal" else { return nil }
        guard let data = try? JSONEncoder.ccKit().encode(raw) else { return nil }
        return try? JSONDecoder.ccKit().decode(GoalEntry.self, from: data)
    }
}

/// The transcript's one-line marker for a goal event, or nil for one it doesn't show: a check that found the goal
/// not yet met is in the goal row above the composer, not in the transcript.
public func goalCaption(_ entry: GoalEntry) -> (symbol: String, text: String)? {
    let condition = (entry.condition ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    switch entry.status {
    case "set":
        return condition.isEmpty ? nil : ("target", "Goal: \(condition)")
    case "met":
        var parts = ["Goal met"]
        if let iterations = entry.iterations, iterations > 0 { parts.append(iterations == 1 ? "1 check" : "\(iterations) checks") }
        if let durationMs = entry.durationMs, durationMs > 0 { parts.append(goalDurationText(seconds: Double(durationMs) / 1000)) }
        return ("checkmark.circle", parts.joined(separator: " · "))
    case "failed":
        let reason = (entry.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ("xmark.circle", reason.isEmpty ? "Goal stopped" : "Goal stopped: \(reason)")
    case "cleared":
        return ("target", "Goal cleared")
    default:
        return nil
    }
}

/// "45s", "12m" or "1h 5m": how long a goal has been running, in the goal row and the met marker.
public func goalDurationText(seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    if total < 60 { return "\(total)s" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
}

/// The goal row's second line: "Goal · 12m · 3 checks", without the parts the controller didn't say.
public func goalStatusLine(_ goal: SessionGoal, now: Date) -> String {
    var parts = ["Goal"]
    if let since = goal.since { parts.append(goalDurationText(seconds: now.timeIntervalSince(since))) }
    if let checks = goal.checks, checks > 0 { parts.append(checks == 1 ? "1 check" : "\(checks) checks") }
    return parts.joined(separator: " · ")
}
