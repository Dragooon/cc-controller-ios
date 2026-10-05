import Foundation

public func sessionsSubtitle(_ sessions: [Session]) -> String? {
    guard !sessions.isEmpty else { return nil }
    if sessions.allSatisfy({ sessionActivity($0) == .idle }) { return "All idle" }

    let needsYou = sessions.filter { sessionActivity($0) == .needsYou }.count
    let working = sessions.filter {
        switch sessionActivity($0) {
        case .working, .background: true
        case .needsYou, .idle: false
        }
    }.count
    var parts: [String] = []
    if needsYou > 0 { parts.append("\(needsYou) needs you") }
    if working > 0 { parts.append("\(working) working") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// Formats a daemon probe duration as rounded milliseconds for the connection card.
public func latencyText(_ latency: Duration) -> String {
    let components = latency.components
    let milliseconds = Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
    return "\(max(1, Int(milliseconds.rounded()))) ms"
}

/// Formats elapsed milliseconds without trailing zero-valued units.
public func displayDuration(_ milliseconds: Int) -> String {
    let clampedMilliseconds = max(0, milliseconds)
    if clampedMilliseconds < 10_000 {
        let seconds = Double(clampedMilliseconds) / 1000
        return String(format: "%.1fs", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    let totalSeconds = Int((Double(clampedMilliseconds) / 1000).rounded())
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    if minutes > 0 {
        return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
    }
    return "\(seconds)s"
}

/// Builds the compact native session detail subtitle without web-only spacing.
public func sessionDetailSubtitle(_ session: Session, now: Date = .now) -> String {
    let activity = sessionActivity(session)
    let state: String
    switch activity {
    case .needsYou: state = "needs you"
    case .working: state = "working"
    case .background: state = "background"
    case .idle: state = "idle"
    }
    var parts = [state]

    switch activity {
    case .background:
        if let summary = activitySummaryText(for: session) { parts.append(summary) }
    case .working:
        if let started = session.startedAt {
            let milliseconds = max(0, Int(started.distance(to: now) * 1000.0))
            parts.append(displayDuration(milliseconds))
        }
    case .needsYou:
        if let started = session.pending?.first?.receivedAt ?? session.idleSince {
            let milliseconds = max(0, Int(started.distance(to: now) * 1000.0))
            parts.append(displayDuration(milliseconds))
        }
    case .idle:
        if let started = session.idleSince {
            let milliseconds = max(0, Int(started.distance(to: now) * 1000.0))
            parts.append(displayDuration(milliseconds))
        }
    }

    let context = formatContextUsage(session.usage)
    if !context.isEmpty {
        parts.append(context)
    }

    return parts.joined(separator: " · ")
}

/// Formats a subagent's lowercase state and elapsed time for its navigation subtitle.
public func subagentSubtitle(_ subagent: Subagent, now: Date = .now) -> String {
    var parts: [String] = []
    if let state = subagent.state {
        parts.append(state.rawValue.lowercased().replacingOccurrences(of: "_", with: " "))
    }
    if let started = subagent.startedAt {
        let end = subagent.finishedAt ?? now
        let milliseconds = max(0, Int(started.distance(to: end) * 1000.0))
        parts.append(displayDuration(milliseconds))
    }
    return parts.joined(separator: " · ")
}

/// Names a native tool group according to whether any member is still running.
public func nativeToolRunLabel(_ run: ToolRun) -> String {
    run.isRunning ? "Running \(run.entries.count) tools" : "Ran \(run.entries.count) tools"
}

/// Formats the fallback countdown shown on a remote approval card.
public func approvalFallbackText(remaining: TimeInterval) -> String {
    let seconds = max(0, Int(ceil(remaining)))
    return "falls back to the terminal in \(seconds / 60):\(String(format: "%02d", seconds % 60))"
}

/// Formats the terminal handoff time using the user's short time convention.
public func approvalWaitingText(
    since: Date,
    calendar: Calendar = .current,
    timeZone: TimeZone = .current,
    locale: Locale = .current
) -> String {
    var calendar = calendar
    calendar.timeZone = timeZone
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return "Waiting in the terminal since \(formatter.string(from: since))"
}

public func moreWaitingText(count: Int) -> String? {
    guard count > 0 else { return nil }
    return "\(count) more waiting"
}

public func approvalHoldFraction(remaining: TimeInterval, total: TimeInterval) -> Double {
    guard total > 0 else { return 0 }
    return min(1, max(0, remaining / total))
}
