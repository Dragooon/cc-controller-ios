import CCKit
import SwiftUI
import UIKit

struct InspectorView: View {
    let session: Session
    let elapsed: String?
    let branch: String?
    let onInterrupt: () -> Void
    let onCopySessionID: () -> Void
    let onApprovalMode: (ApprovalMode) -> Void
    let onSubagent: (Subagent) -> Void
    /// False when the owning controller does not advertise `interrupt`.
    let canInterrupt: Bool
    /// False when the owning controller does not advertise `mode`.
    let canSetApprovalMode: Bool

    @State private var isInterruptConfirmationPresented = false
    @State private var attachCommandCopied = false

    private let approvalModes: [(mode: String, title: String, description: String)] = [
        ("auto", "Auto", "Ask in the terminal when it's open on the Mac, otherwise on this iPhone."),
        ("remote", "Remote", "Ask on this iPhone first. After about 10 minutes the terminal takes over."),
        ("terminal", "Terminal", "Always ask in the Mac's terminal."),
    ]

    init(
        session: Session,
        elapsed: String? = nil,
        branch: String? = nil,
        onInterrupt: @escaping () -> Void = {},
        onCopySessionID: @escaping () -> Void = {},
        onApprovalMode: @escaping (ApprovalMode) -> Void = { _ in },
        onSubagent: @escaping (Subagent) -> Void = { _ in },
        canInterrupt: Bool = true,
        canSetApprovalMode: Bool = true
    ) {
        self.session = session
        self.elapsed = elapsed
        self.branch = branch
        self.onInterrupt = onInterrupt
        self.onCopySessionID = onCopySessionID
        self.onApprovalMode = onApprovalMode
        self.onSubagent = onSubagent
        self.canInterrupt = canInterrupt
        self.canSetApprovalMode = canSetApprovalMode
    }

    private var usage: Usage? { session.usage }
    private var currentMode: String { session.mode?.rawValue ?? "auto" }
    private var currentModeTitle: String {
        approvalModes.first(where: { $0.mode == currentMode })?.title ?? ""
    }
    private var sortedSubagents: [Subagent] {
        (session.subagents ?? []).sorted { left, right in
            (left.state == .running ? 0 : 1) < (right.state == .running ? 0 : 1)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                contextSection
                usageSection
                subagentsSection
                if canSetApprovalMode {
                    approvalsSection
                }
                conversationSection
                locationSection
                openOnMacSection
                actionsSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(.ccBackground)
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.ccAccent)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            "Interrupt this session?",
            isPresented: $isInterruptConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Interrupt", role: .destructive, action: onInterrupt)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current turn will stop in the terminal pane.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if hasStatusData {
            Section {
                if let state = session.state {
                    LabeledContent("State") {
                        HStack(spacing: 7) {
                            if state == .working {
                                SpinnerGlyph(active: true, frozen: false)
                                    .accessibilityHidden(true)
                            }
                            Text(stateLabel(state: state.rawValue))
                                .foregroundStyle(state == .needsYou ? .ccAccent : .ccSecondary)
                        }
                    }
                }
                if elapsed != nil || elapsedAnchor != nil {
                    LabeledContent("Elapsed") {
                        LiveElapsedText(
                            startedAt: elapsedAnchor,
                            finishedAt: nil,
                            isLive: isSessionLive,
                            fallback: elapsed
                        )
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.ccSecondary)
                        .accessibilityIdentifier("inspector-elapsed")
                    }
                }
                if let model = formattedModel {
                    LabeledContent("Model") {
                        Text(model)
                            .foregroundStyle(.ccSecondary)
                    }
                }
            } header: {
                sectionHeader("Status")
            }
        }
    }

    @ViewBuilder
    private var contextSection: some View {
        if hasContextData {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if let percent = positivePercent(usage?.contextPercent) {
                        HStack(alignment: .center, spacing: 12) {
                            Gauge(value: percent / 100, in: 0...1) {
                                EmptyView()
                            } currentValueLabel: {
                                EmptyView()
                            }
                            .gaugeStyle(.linearCapacity)
                            .tint(.ccAccent)
                            .frame(maxWidth: .infinity)

                            Text("\(Int(percent.rounded()))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.ccLabel)
                        }
                    }
                    if let contextTokens = positiveInt(usage?.contextTokens),
                       let contextWindow = positiveInt(usage?.contextWindow) {
                        Text("\(formatTokenCount(contextTokens)) of \(formatTokenCount(contextWindow)) tokens")
                            .font(.footnote)
                            .foregroundStyle(.ccSecondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("inspector-context")
                .accessibilityLabel(contextAccessibilityLabel)
                .accessibilityRemoveTraits(.isButton)
            } header: {
                sectionHeader("Context")
            }
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        if hasUsageData {
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    if let input = positiveInt(usage?.totalInputTokens ?? usage?.inputTokens) {
                        StatTile(value: formatTokenCount(input), label: "Input")
                    }
                    if let output = positiveInt(usage?.outputTokens) {
                        StatTile(value: formatTokenCount(output), label: "Output")
                    }
                    if let cache = positiveCacheRate(usage?.cacheHitRate) {
                        StatTile(value: "\(Int(cache.rounded()))%", label: "Cache")
                    }
                    if let messages = positiveInt(usage?.messages) {
                        let responseLabel = messages == 1 ? "Response" : "Responses"
                        StatTile(value: formatTokenCount(messages), label: responseLabel)
                            .accessibilityElement(children: .ignore)
                            .accessibilityIdentifier("inspector-responses")
                            .accessibilityLabel("\(formatTokenCount(messages)) \(responseLabel)")
                    }
                }
                .padding(.vertical, 2)
            } header: {
                sectionHeader("Usage")
            }
        }
    }

    @ViewBuilder
    private var subagentsSection: some View {
        if !sortedSubagents.isEmpty {
            Section {
                ForEach(Array(sortedSubagents.enumerated()), id: \.offset) { _, subagent in
                    Button { onSubagent(subagent) } label: {
                        HStack(spacing: 10) {
                            if subagent.state == .running {
                                SpinnerGlyph(active: true, frozen: false)
                                    .font(.subheadline)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                            } else {
                                Circle()
                                    .fill(subagent.state == .failed ? .ccRed : .ccGreen)
                                    .frame(width: 8, height: 8)
                                    .frame(width: 18)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(subagent.agent ?? "agent")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.ccLabel)
                                if let brief = subagent.text, !brief.isEmpty {
                                    Text(brief)
                                        .font(.footnote)
                                        .foregroundStyle(.ccSecondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            if subagent.startedAt != nil {
                                LiveElapsedText(
                                    startedAt: subagent.startedAt,
                                    finishedAt: subagent.finishedAt,
                                    isLive: subagent.state == .running,
                                    fallback: nil
                                )
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.ccSecondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.ccSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inspector-subagent-\(subagent.agentId ?? "")")
                    .accessibilityLabel(subagentAccessibilityLabel(subagent))
                    .accessibilityElement(children: .combine)
                    .disabled(subagent.agentId == nil)
                }
            } header: {
                sectionHeader("Subagents")
            }
        }
    }

    private var approvalsSection: some View {
        Section {
            Picker("Approval mode", selection: Binding(
                get: { currentMode },
                set: { onApprovalMode(approvalMode(for: $0)) }
            )) {
                ForEach(approvalModes, id: \.mode) { choice in
                    Text(choice.title).tag(choice.mode)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("approval-mode-picker")
            .accessibilityValue(currentModeTitle)

            if let selected = approvalModes.first(where: { $0.mode == currentMode }) {
                Text(selected.description)
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            sectionHeader("Approvals")
        }
    }

    /// Stockade sessions: who started it, who's in it, and whether the app can write.
    @ViewBuilder
    private var conversationSection: some View {
        if session.origin != nil || session.writable != nil {
            Section {
                if let agent = session.agent {
                    LabeledContent("Agent") {
                        Text(agent.name ?? agent.id)
                            .foregroundStyle(.ccSecondary)
                    }
                }
                if let origin = sessionOriginLabel(session.origin) {
                    LabeledContent("Started in") {
                        Text(origin)
                            .foregroundStyle(.ccSecondary)
                    }
                }
                if let starter = session.startedBy {
                    LabeledContent("Started by") {
                        Text(starter.name)
                            .foregroundStyle(.ccSecondary)
                    }
                }
                if let participants = session.participants, !participants.isEmpty {
                    LabeledContent("People") {
                        Text(participants.map(\.name).joined(separator: ", "))
                            .foregroundStyle(.ccSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityIdentifier("inspector-participants")
                }
                LabeledContent("Access") {
                    Text(readOnlyLabel(for: session) ?? "Read and write")
                        .foregroundStyle(.ccSecondary)
                }
                .accessibilityIdentifier("inspector-access")
                if session.sudo == true {
                    LabeledContent("Sudo") {
                        Text("On")
                            .foregroundStyle(.ccAmber)
                    }
                    .accessibilityIdentifier("inspector-sudo")
                }
            } header: {
                sectionHeader("Conversation")
            }
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        if hasLocationData {
            Section {
                if let project = nonEmpty(session.project) {
                    LabeledContent("Project") {
                        Text(project)
                            .foregroundStyle(.ccSecondary)
                    }
                }
                if let branch = nonEmpty(branch) {
                    LabeledContent("Branch") {
                        Text(branch)
                            .foregroundStyle(.ccSecondary)
                    }
                }
                if let tmuxPane = nonEmpty(session.tmuxPane) {
                    LabeledContent("tmux pane") {
                        Text(tmuxPane)
                            .foregroundStyle(.ccSecondary)
                    }
                }
            } header: {
                sectionHeader("Location")
            }
        }
    }

    @ViewBuilder
    private var openOnMacSection: some View {
        if let shortId = session.background?.shortId, !shortId.isEmpty {
            Section {
                Button {
                    UIPasteboard.general.string = "claude attach \(shortId)"
                    attachCommandCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        attachCommandCopied = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("claude attach \(shortId)")
                            .font(.body.monospaced())
                            .foregroundStyle(.ccLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Image(systemName: attachCommandCopied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(.ccSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inspector-open-on-mac")
                .accessibilityLabel(attachCommandCopied ? "Attach command copied" : "Copy attach command")
            } header: {
                sectionHeader("Open on Mac")
            } footer: {
                Text("Run this in a terminal on your Mac to open the session there.")
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if canInterrupt, nonEmpty(session.tmuxPane) != nil {
                Button {
                    isInterruptConfirmationPresented = true
                } label: {
                    Label("Interrupt", systemImage: "stop.circle")
                }
                .foregroundStyle(.ccRed)
                .accessibilityHint("Stops the current turn in the terminal pane")
            }

            Button(action: onCopySessionID) {
                Label("Copy session ID", systemImage: "doc.on.doc")
            }
        } header: {
            sectionHeader("Actions")
        }
    }

    private var hasStatusData: Bool {
        session.state != nil || elapsed != nil || elapsedAnchor != nil || formattedModel != nil
    }

    private var hasContextData: Bool {
        positivePercent(usage?.contextPercent) != nil ||
            (positiveInt(usage?.contextTokens) != nil && positiveInt(usage?.contextWindow) != nil)
    }

    private var hasUsageData: Bool {
        positiveInt(usage?.totalInputTokens ?? usage?.inputTokens) != nil ||
            positiveInt(usage?.outputTokens) != nil ||
            positiveCacheRate(usage?.cacheHitRate) != nil ||
            positiveInt(usage?.messages) != nil
    }

    private var hasLocationData: Bool {
        nonEmpty(session.project) != nil || nonEmpty(branch) != nil || nonEmpty(session.tmuxPane) != nil
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.ccLabel)
    }

    private func subagentAccessibilityLabel(_ subagent: Subagent) -> String {
        let name = subagent.agent ?? "agent"
        let state = subagent.state?.rawValue ?? "unknown"
        var parts = [name, state]
        if let text = subagent.text, !text.isEmpty {
            parts.append(text)
        }
        if let startedAt = subagent.startedAt {
            let finishedAt = subagent.finishedAt ?? Date()
            parts.append(formatDuration(finishedAt.timeIntervalSince(startedAt) * 1000))
        }
        return parts.joined(separator: ", ")
    }

    private var elapsedAnchor: Date? {
        switch session.state {
        case .working: session.startedAt
        case .needsYou: session.pending?.first?.receivedAt ?? session.idleSince
        default: session.idleSince
        }
    }

    private var isSessionLive: Bool {
        session.state == .working || session.state == .needsYou
    }

    private var formattedModel: String? {
        nonEmpty(formatModelName(usage?.model))
    }

    private var contextAccessibilityLabel: String {
        var parts = ["Context"]
        if let percent = positivePercent(usage?.contextPercent) {
            parts.append("\(Int(percent.rounded())) percent")
        }
        if let contextTokens = positiveInt(usage?.contextTokens),
           let contextWindow = positiveInt(usage?.contextWindow) {
            parts.append("\(formatTokenCount(contextTokens)) of \(formatTokenCount(contextWindow)) tokens")
        }
        return parts.joined(separator: ", ")
    }

    private func approvalMode(for rawValue: String) -> ApprovalMode {
        switch rawValue {
        case "auto": .auto
        case "remote": .remote
        case "terminal": .terminal
        default: .unknown(rawValue)
        }
    }

    private func positiveInt(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private func positivePercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return min(value, 100)
    }

    private func positiveCacheRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return min(value <= 1 ? value * 100 : value, 100)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(.ccLabel)
            Text(label)
                .font(.caption)
                .foregroundStyle(.ccSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ccCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
