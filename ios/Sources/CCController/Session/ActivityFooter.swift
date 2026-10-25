import CCKit
import SwiftUI

struct LiveActivityFooterView: View {
    let footer: CCKit.ActivityFooter
    let session: Session?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(footer: CCKit.ActivityFooter, session: Session? = nil) {
        self.footer = footer
        self.session = session
    }

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.activityFooter)
        #endif
        if footer.isWaiting {
            content(footer)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(currentFooter(now: context.date))
            }
        }
    }

    private func content(_ current: CCKit.ActivityFooter) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ActivityGlyph(active: !current.isWaiting, reduceMotion: reduceMotion)
                .font(.footnote)

            Text(current.primary)
                .font(.subheadline)
                .foregroundStyle(current.isWaiting ? .ccAmber : .ccAccent)
                .lineLimit(1)
                .truncationMode(.tail)

            if !current.detail.isEmpty {
                Text("· \(current.detail)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.ccSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("live-activity-row")
        .accessibilityLabel(accessibilityText(current))
    }

    private func currentFooter(now: Date) -> CCKit.ActivityFooter {
        guard let session else { return footer }
        let verb = footer.primary.components(separatedBy: "…").first ?? "Thinking"
        let current = activityFooterText(session, now: now, verb: verb, startedAt: footer.startedAt)
        guard let outputTokens = footer.outputTokens, !current.isWaiting else { return current }
        let detail = current.detail.isEmpty ? "" : "\(current.detail) · ↓ \(formatTokenCount(outputTokens))"
        return ActivityFooter(
            primary: current.primary,
            detail: detail,
            isWaiting: current.isWaiting,
            startedAt: current.startedAt,
            outputTokens: outputTokens
        )
    }

    private func accessibilityText(_ current: CCKit.ActivityFooter) -> String {
        current.detail.isEmpty ? current.primary : "\(current.primary), \(current.detail)"
    }
}

private struct ActivityGlyph: View {
    let active: Bool
    let reduceMotion: Bool
    @State private var rotation = 0.0

    var body: some View {
        Text("✻")
            .foregroundStyle(active ? .ccAccent : .ccAmber)
            .rotationEffect(.degrees(rotation))
            .animation(reduceMotion ? nil : .linear(duration: 8).repeatForever(autoreverses: false), value: rotation)
            .onAppear {
                guard active, !reduceMotion else { return }
                rotation = 360
            }
            .accessibilityHidden(true)
    }
}
