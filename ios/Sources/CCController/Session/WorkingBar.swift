import CCKit
import SwiftUI

struct WorkingBarView: View {
    let session: Session
    let verb: String
    let frozenNow: Date?
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ccFreezeLiveIndicators) private var freezeLiveIndicators

    init(
        session: Session,
        verb: String,
        frozenNow: Date? = nil,
        onTap: @escaping () -> Void = {}
    ) {
        self.session = session
        self.verb = verb
        self.frozenNow = frozenNow
        self.onTap = onTap
    }

    var body: some View {
        timedBody
    }

    @ViewBuilder
    private var timedBody: some View {
        if let frozenNow {
            content(now: frozenNow)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(now: context.date)
            }
        }
    }

    private func content(now: Date) -> some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SpinnerGlyph(active: true, frozen: false)
                        .font(.footnote)
                    Text(primaryText)
                        .font(.footnote.weight(toolIsRunning ? .regular : .semibold))
                        .liveIndicatorTextAnimation(
                            enabled: !freezeLiveIndicators,
                            value: primaryText,
                            reduceMotion: reduceMotion
                        )
                        .foregroundStyle(.ccLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                trailing(now: now)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(now: now))
        .accessibilityHint("Shows activity")
        .accessibilityIdentifier("working-bar")
    }

    private func trailing(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(elapsedText(now: now) + tokenText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.ccSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let activitySummary = activitySummaryText(for: session) {
                Text(activitySummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.ccAccent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(.ccAccent.opacity(0.13), in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(activitySummaryText(for: session) == nil ? .ccSecondary : .ccAccent)
        }
    }

    private var toolIsRunning: Bool {
        session.toolRunning == true && !(session.lastTool ?? "").isEmpty
    }

    private var primaryText: String {
        toolIsRunning ? activityLineText(session) : "\(verb)…"
    }

    private var tokenText: String {
        guard let outputTokens = session.usage?.outputTokens, outputTokens > 0 else { return "" }
        return " · ↓ \(formatTokenCount(outputTokens))"
    }

    private func elapsedText(now: Date) -> String {
        let milliseconds = max(0, (now.timeIntervalSince(session.startedAt ?? now)) * 1000)
        return formatDuration(milliseconds)
    }

    private func accessibilityText(now: Date) -> String {
        var parts = [primaryText, elapsedText(now: now)]
        if let outputTokens = session.usage?.outputTokens, outputTokens > 0 {
            parts.append("down \(formatTokenCount(outputTokens)) tokens")
        }
        if let summary = activitySummaryText(for: session) {
            parts.append(summary)
        }
        return parts.joined(separator: ", ")
    }
}
