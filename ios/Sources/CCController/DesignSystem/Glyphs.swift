import CCKit
import SwiftUI

/// Proposes at most `cap` points of height to its single child and reports the child's own size, so the child never grows to the cap.
struct CappedHeightLayout: Layout {
    var cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let height = min(proposal.height ?? cap, cap)
        return child.sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

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
    let onOpen: () -> Void
    let onAllow: () -> Void
    let onAllowSession: () -> Void
    let onDeny: () -> Void
    let glassNamespace: Namespace.ID?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var fullActionHeight = CCMetrics.actionHeight
    @ScaledMetric(relativeTo: .body) private var compactActionHeight = CCMetrics.compactActionHeight

    init(
        approval: Approval,
        style: Style,
        now: Date,
        onOpen: @escaping () -> Void = {},
        onAllow: @escaping () -> Void = {},
        onAllowSession: @escaping () -> Void = {},
        onDeny: @escaping () -> Void = {},
        glassNamespace: Namespace.ID? = nil
    ) {
        self.approval = approval
        self.style = style
        self.now = now
        self.onOpen = onOpen
        self.onAllow = onAllow
        self.onAllowSession = onAllowSession
        self.onDeny = onDeny
        self.glassNamespace = glassNamespace
    }

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
        case .compact:
            compactBody
        case .full:
            fullBody
        }
    }

    private var fullBody: some View {
        Group {
            if let glassNamespace {
                fullCard.glassEffectID("composer", in: glassNamespace)
            } else {
                fullCard
            }
        }
    }

    private var fullCard: some View {
        ViewThatFits(in: .vertical) {
            fullCardPlainLayout
            fullCardScrollableLayout
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval for \(approval.toolName ?? "Tool")")
    }

    private var fullCardPlainLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            fullCardBody
            fullActions
        }
    }

    private var fullCardScrollableLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.vertical) {
                fullCardBody
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            fullActions
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var fullCardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            fullHeader

            if !copy.command.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(copy.command)
                        .font(.callout.monospaced())
                        .foregroundStyle(.ccLabel)
                        .lineLimit(commandLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if commandLineCount > commandLineLimit {
                        Button("Show all") {}
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.ccAccent)
                            .buttonStyle(.plain)
                    }
                }
            }

            if !copy.description.isEmpty {
                Text(copy.description)
                    .font(.subheadline)
                    .foregroundStyle(.ccSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isTerminal {
                Text(approvalWaitingText(since: approval.timedOutAt ?? approval.receivedAt ?? now, calendar: Self.calendar, timeZone: Self.sydney, locale: Self.english))
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    countdownTrack
                    Text(approvalFallbackText(remaining: remainingMilliseconds / 1_000))
                        .font(.footnote)
                        .foregroundStyle(.ccSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var countdownTrack: some View {
        Capsule()
            .fill(.ccSeparator)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.ccAccent)
                        .frame(width: proxy.size.width * approvalHoldFraction(
                            remaining: remainingMilliseconds / 1_000,
                            total: Double(copy.holdLimitMs) / 1_000
                        ))
                }
            }
            .accessibilityHidden(true)
    }

    private var fullHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                toolHeader
                if let agentType = approval.agentType {
                    Text("\(agentType) wants to run this")
                        .font(.subheadline)
                        .foregroundStyle(.ccSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                permissionModeChip
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    toolHeader
                    Spacer(minLength: 4)
                    permissionModeChip
                }
                if let agentType = approval.agentType {
                    Text("\(agentType) wants to run this")
                        .font(.subheadline)
                        .foregroundStyle(.ccSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var toolHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ToolSymbol(tool: approval.toolName ?? "Tool")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.ccLabel)
            Text(approval.toolName ?? "Tool")
                .font(.headline)
                .foregroundStyle(.ccLabel)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var permissionModeChip: some View {
        if let permissionMode = approval.permissionMode, permissionMode != "default" {
            Text(permissionMode)
                .font(.caption)
                .foregroundStyle(.ccSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ccSecondary.opacity(0.12), in: Capsule())
        }
    }

    private var fullActions: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                if dynamicTypeSize < .accessibility1 {
                    HStack(spacing: 12) {
                        fullDenyButton
                        fullAllowButton
                    }
                }
                VStack(spacing: 8) {
                    fullAllowButton
                    fullDenyButton
                }
            }

            if isTerminal {
                Text("Your answer is typed into the terminal.")
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if approval.mode == .remote {
                Button(action: onAllowSession) {
                    Text("Allow for this session")
                        .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap)
                        .contentShape(Rectangle())
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.ccAccent)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap)
            }
        }
    }

    private var fullDenyButton: some View {
        Button(role: .destructive, action: onDeny) {
            Text("Deny")
                .foregroundStyle(.ccRed)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: visibleFullActionHeight, maxHeight: visibleFullActionHeight)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap)
        .contentShape(Rectangle())
        .accessibilityLabel(isTerminal ? "Deny in the terminal" : "Deny")
    }

    private var fullAllowButton: some View {
        Button(action: onAllow) {
            Text("Allow")
                .foregroundStyle(.white)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: visibleFullActionHeight, maxHeight: visibleFullActionHeight)
                .glassEffect(.regular.tint(.ccAccent).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap)
        .contentShape(Rectangle())
        .accessibilityLabel(isTerminal ? "Allow in the terminal" : "Allow")
    }

    private var visibleFullActionHeight: CGFloat {
        min(fullActionHeight, 56)
    }

    private var visibleCompactActionHeight: CGFloat {
        min(compactActionHeight, 44)
    }

    private var isTerminal: Bool {
        approval.mode == .terminal || approval.status == .terminal
    }

    private var cardIdentifier: String {
        "approval-card-\(approval.sessionId ?? approval.requestId ?? "unknown")"
    }

    private var actionIdentifierPrefix: String {
        "approval-\(approval.sessionId ?? approval.requestId ?? "unknown")"
    }

    private var commandLineCount: Int {
        copy.command.split(whereSeparator: \.isNewline).count
    }

    private var commandLineLimit: Int {
        dynamicTypeSize >= .accessibility1 ? 4 : 6
    }

    private static let calendar = Calendar(identifier: .gregorian)

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            compactContent

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
        .accessibilityIdentifier(cardIdentifier)
    }

    private var compactContent: some View {
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
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
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
        Button(role: .destructive, action: onDeny) {
            Text("Deny")
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: visibleCompactActionHeight, maxHeight: visibleCompactActionHeight)
                .glassEffect(.regular.interactive(), in: .capsule)
                .foregroundColor(.ccRed)
                .foregroundStyle(.ccRed)
        }
        .tint(.ccRed)
        .buttonStyle(.plain)
        .foregroundStyle(.ccRed)
        .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap)
        .contentShape(Rectangle())
        .accessibilityIdentifier("\(actionIdentifierPrefix)-deny")
    }

    private var allowButton: some View {
        Button(action: onAllow) {
            Text("Allow")
                .foregroundStyle(.white)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: visibleCompactActionHeight, maxHeight: visibleCompactActionHeight)
                .glassEffect(.regular.tint(.ccAccent).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap)
        .contentShape(Rectangle())
        .accessibilityIdentifier("\(actionIdentifierPrefix)-allow")
    }

    private static let sydney = TimeZone(identifier: "Australia/Sydney")!
    private static let english = Locale(identifier: "en_AU")
}
