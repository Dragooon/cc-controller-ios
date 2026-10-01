import CCKit
import SwiftUI

struct ApprovalBottomStackView: View {
    let approvals: [Approval]
    let deciding: Set<String>
    let now: Date
    let maxHeight: CGFloat
    let onAllow: (Approval) -> Void
    let onAllowSession: (Approval) -> Void
    let onDeny: (Approval) -> Void
    let glassNamespace: Namespace.ID?
    let inGlassContainer: Bool

    @Namespace private var fallbackGlassNamespace
    @ScaledMetric(relativeTo: .body) private var waitingRowHeight = 36
    @State private var isExpanded = false

    init(
        approvals: [Approval],
        deciding: Set<String> = [],
        now: Date,
        maxHeight: CGFloat,
        onAllow: @escaping (Approval) -> Void = { _ in },
        onAllowSession: @escaping (Approval) -> Void = { _ in },
        onDeny: @escaping (Approval) -> Void = { _ in },
        glassNamespace: Namespace.ID? = nil,
        inGlassContainer: Bool = true
    ) {
        self.approvals = approvals
        self.deciding = deciding
        self.now = now
        self.maxHeight = maxHeight
        self.onAllow = onAllow
        self.onAllowSession = onAllowSession
        self.onDeny = onDeny
        self.glassNamespace = glassNamespace
        self.inGlassContainer = inGlassContainer
    }

    var body: some View {
        if inGlassContainer {
            GlassEffectContainer(spacing: 8) {
                stackContent
            }
        } else {
            stackContent
        }
    }

    private var stackContent: some View {
        VStack(spacing: 8) {
            ForEach(Array(displayedApprovals.enumerated()), id: \.offset) { index, approval in
                CappedHeightLayout(cap: cardMaxHeight) {
                    ApprovalCard(
                        approval: approval,
                        style: .full,
                        now: now,
                        onAllow: { onAllow(approval) },
                        onAllowSession: { onAllowSession(approval) },
                        onDeny: { onDeny(approval) },
                        glassNamespace: index == 0 ? effectiveGlassNamespace : nil
                    )
                    .disabled(isDeciding(approval))
                }
            }

            if let waiting = moreWaitingText(count: max(0, approvals.count - 1)) {
                Button {
                    withAnimation(.smooth) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(isExpanded ? "Show latest approval" : waiting)
                        Spacer(minLength: 0)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.ccLabel)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: visibleWaitingRowHeight, maxHeight: visibleWaitingRowHeight)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap)
                .contentShape(Rectangle())
                .accessibilityLabel(isExpanded ? "Show latest approval" : waiting)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(.smooth, value: approvalIDs)
    }

    private var displayedApprovals: [Approval] {
        isExpanded ? approvals : Array(approvals.prefix(1))
    }

    private var effectiveGlassNamespace: Namespace.ID {
        glassNamespace ?? fallbackGlassNamespace
    }

    private var approvalIDs: [String] {
        approvals.compactMap(\.requestId)
    }

    private func isDeciding(_ approval: Approval) -> Bool {
        guard let key = approvalDecisionKey(approval) else { return false }
        return deciding.contains(key)
    }

    private var visibleWaitingRowHeight: CGFloat {
        min(waitingRowHeight, 44)
    }

    private var cardMaxHeight: CGFloat {
        let waitingHeight: CGFloat = moreWaitingText(count: max(0, approvals.count - 1)) == nil ? 0 : visibleWaitingRowHeight
        let waitingSpacing: CGFloat = waitingHeight == 0 ? 0 : 8
        return max(0, maxHeight - 8 - 4 - waitingHeight - waitingSpacing)
    }
}

func approvalDecisionKey(_ approval: Approval) -> String? {
    guard let sessionID = approval.sessionId, let requestID = approval.requestId, !requestID.isEmpty else { return nil }
    return "\(sessionID):\(requestID)"
}
