import CCKit
import SwiftUI

struct LiveElapsedText: View {
    let startedAt: Date?
    let finishedAt: Date?
    let isLive: Bool
    let fallback: String?

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.liveClock)
        #endif
        if let fallback, !fallback.isEmpty {
            Text(fallback)
        } else if let startedAt {
            if isLive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(duration(startedAt: startedAt, endedAt: context.date))
                }
            } else {
                Text(duration(startedAt: startedAt, endedAt: finishedAt ?? .now))
            }
        } else {
            Text(displayDuration(0))
        }
    }

    private func duration(startedAt: Date, endedAt: Date) -> String {
        displayDuration(max(0, Int(startedAt.distance(to: endedAt) * 1000)))
    }
}

struct SessionSubtitleView: View {
    let session: Session

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.liveClock)
        #endif
        if isLive, hasAnchor {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(sessionDetailSubtitle(session, now: context.date))
            }
        } else {
            Text(sessionDetailSubtitle(session))
        }
    }

    private var isLive: Bool {
        session.state == .working || session.state == .needsYou
    }

    private var hasAnchor: Bool {
        switch session.state {
        case .working: session.startedAt != nil
        case .needsYou: session.pending?.first?.receivedAt != nil || session.idleSince != nil
        default: session.idleSince != nil
        }
    }
}

struct SubagentSubtitleView: View {
    let subagent: Subagent

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.liveClock)
        #endif
        if subagent.state == .running, subagent.startedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(subagentSubtitle(subagent, now: context.date))
            }
        } else {
            Text(subagentSubtitle(subagent))
        }
    }
}

struct SessionStateSegmentView: View {
    let session: Session

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.liveClock)
        #endif
        if isLive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(value(now: context.date))
            }
        } else {
            Text(value(now: .now))
        }
    }

    private var isLive: Bool {
        session.state == .working || session.state == .needsYou || activityCounts(for: session).agents > 0 || activityCounts(for: session).shells > 0
    }

    private func value(now: Date) -> String {
        [
            sessionListStateSegment(session, now: now),
            activitySummaryText(for: session) ?? "",
            formatContextUsage(session.usage),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
        .replacingOccurrences(of: " 0s", with: "")
    }
}
