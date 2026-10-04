import CCKit
import SwiftUI

struct StatusLineView: View {
    let segments: [String]
    let activitySession: Session?
    let onActivity: () -> Void

    init(segments: [String], activitySession: Session? = nil, onActivity: @escaping () -> Void = {}) {
        self.segments = segments
        self.activitySession = activitySession
        self.onActivity = onActivity
    }

    private var fullText: String { segments.joined(separator: " · ") }
    private var reducedText: String { segments.prefix(2).joined(separator: " · ") }
    private var shortestText: String { segments.first ?? "" }
    private var activitySummary: String? { activitySession.flatMap(activitySummaryText) }

    var body: some View {
        Group {
            if activitySummary != nil {
                activityLayout
                    .accessibilityElement(children: .contain)
            } else {
                regularLayout
                    .accessibilityLabel(fullText.replacingOccurrences(of: " · ", with: ", "))
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.ccSecondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
    }

    private var regularLayout: some View {
        ViewThatFits(in: .horizontal) {
            statusText(fullText)
            statusText(reducedText)
            statusText(shortestText)
        }
    }

    private var activityLayout: some View {
        ViewThatFits(in: .horizontal) {
            activityRow { statusText(fullText) }
            activityRow { statusText(reducedText) }
            activityRow { statusText(shortestText) }
            activityRow { EmptyView() }
        }
    }

    private func activityRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            activityButton
            if !segments.isEmpty {
                Text("·")
                    .accessibilityHidden(true)
                content()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var activityButton: some View {
        Button(action: onActivity) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                PulsingAccentDot()
                Text(activitySummary ?? "")
                    .font(.caption.monospaced())
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.ccAccent)
        .accessibilityLabel(activityAccessibilityLabel)
        .accessibilityHint("Shows activity")
        .accessibilityIdentifier("activity-status")
    }

    private var activityAccessibilityLabel: String {
        guard let session = activitySession else { return "Activity" }
        let counts = activityCounts(for: session)
        var parts: [String] = []
        if counts.agents > 0 { parts.append("\(counts.agents) agent\(counts.agents == 1 ? "" : "s")") }
        if counts.shells > 0 { parts.append("\(counts.shells) shell\(counts.shells == 1 ? "" : "s")") }
        return parts.joined(separator: " and ") + " running"
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: true, vertical: false)
    }
}

// Static on purpose: this dot is on screen whenever agents run, and a repeating animation keeps the display link busy.
private struct PulsingAccentDot: View {
    var body: some View {
        Circle()
            .fill(.ccAccent)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}
