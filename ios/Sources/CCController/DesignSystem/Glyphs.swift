import CCKit
import SwiftUI

struct SpinnerGlyph: View {
    let active: Bool
    let frozen: Bool
    let dimmed: Bool

    init(active: Bool, frozen: Bool, dimmed: Bool = false) {
        self.active = active
        self.frozen = frozen
        self.dimmed = dimmed
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let frames = ["·︎", "✢︎", "✳︎", "✶︎", "✻︎", "✽︎", "✻︎", "✶︎", "✳︎", "✢︎"]

    var body: some View {
        if !active {
            Text("○")
                .foregroundStyle(.ccTertiary)
        } else if frozen || reduceMotion {
            Text("✻︎")
                .foregroundStyle(dimmed ? Color.ccTertiary : Color.ccAccent)
        } else {
            TimelineView(.periodic(from: .now, by: 0.12)) { context in
                let elapsed = max(0, context.date.timeIntervalSinceReferenceDate)
                let frame = frames[Int(elapsed / 0.12) % frames.count]
                Text(frame)
                    .foregroundStyle(.ccAccent)
            }
        }
    }
}

struct ToolSymbol: View {
    let tool: String

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel(tool)
    }

    private var symbolName: String {
        switch tool {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "Write": "square.and.pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        case "Skill": "sparkles"
        default: "wrench.and.screwdriver"
        }
    }
}

struct ApprovalCard: View {
    enum Style {
        case compact
        case full
    }

    let approval: Approval
    let style: Style
    let now: Date
    let onAllow: () -> Void
    let onAllowSession: () -> Void
    let onDeny: () -> Void

    private var copy: PermissionCopy {
        permissionCopy(approval, timeZone: Self.sydney, locale: Self.english)
    }

    private var remainingMilliseconds: Double {
        guard let receivedAt = approval.receivedAt else { return Double(approval.holdLimitMs ?? 0) }
        let limit = Double(approval.holdLimitMs ?? 600_000)
        let elapsed = max(0, now.timeIntervalSince(receivedAt) * 1000)
        return max(0, limit - elapsed)
    }

    var body: some View {
        switch style {
        case .compact, .full:
            compactBody
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                compactHeader
                stackedHeader
            }

            if !copy.command.isEmpty {
                Text(copy.command)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.ccLabel)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }

            if !copy.description.isEmpty {
                Text(copy.description)
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .lineLimit(2)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    denyButton
                    allowButton
                }
                VStack(spacing: 12) {
                    allowButton
                    denyButton
                }
            }
        }
        .padding(13)
        .background(.ccBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.ccAccent.opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval for \(copy.header)")
    }

    private var compactHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ToolSymbol(tool: approval.toolName ?? "Tool")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ccAccent)
            Text(copy.header)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ccLabel)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4)
            countdown
        }
    }

    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ToolSymbol(tool: approval.toolName ?? "Tool")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ccAccent)
                Text(copy.header)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ccLabel)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            countdown
                .padding(.leading, 28)
        }
    }

    private var countdown: some View {
        Text(formatCountdown(remainingMilliseconds))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.ccSecondary)
            .fixedSize()
            .accessibilityLabel("Time remaining \(formatCountdown(remainingMilliseconds))")
    }

    private var denyButton: some View {
        Button(action: onDeny) {
            Text("Deny")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .tint(.ccLabel)
        .controlSize(.large)
    }

    private var allowButton: some View {
        Button(action: onAllow) {
            Text("Allow")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.ccAccent)
        .controlSize(.large)
    }

    private static let sydney = TimeZone(identifier: "Australia/Sydney")!
    private static let english = Locale(identifier: "en_AU")
}
