import CCKit
import SwiftUI

struct InspectorView: View {
    let session: Session
    let elapsed: String?
    let branch: String?
    let now: Date
    let freezeWorkingGlyphs: Bool
    let onInterrupt: () -> Void
    let onCopySessionID: () -> Void
    let onApprovalMode: (ApprovalMode) -> Void
    let onSubagent: (Subagent) -> Void

    @State private var isInterruptConfirmationPresented = false

    private let approvalModes: [(mode: String, title: String, description: String)] = [
        ("auto", "Auto", "Ask in the terminal when it's open on the Mac, otherwise on this iPhone."),
        ("remote", "Remote", "Ask on this iPhone first. After about 10 minutes the terminal takes over."),
        ("terminal", "Terminal", "Always ask in the Mac's terminal."),
    ]

    init(
        session: Session,
        elapsed: String? = nil,
        branch: String? = nil,
        now: Date = .now,
        freezeWorkingGlyphs: Bool = false,
        onInterrupt: @escaping () -> Void = {},
        onCopySessionID: @escaping () -> Void = {},
        onApprovalMode: @escaping (ApprovalMode) -> Void = { _ in },
        onSubagent: @escaping (Subagent) -> Void = { _ in }
    ) {
        self.session = session
        self.elapsed = elapsed
        self.branch = branch
        self.now = now
        self.freezeWorkingGlyphs = freezeWorkingGlyphs
        self.onInterrupt = onInterrupt
        self.onCopySessionID = onCopySessionID
        self.onApprovalMode = onApprovalMode
        self.onSubagent = onSubagent
    }

    private var usage: Usage? { session.usage }
    private var currentMode: String { session.mode?.rawValue ?? "auto" }
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
                approvalsSection
                locationSection
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
        Section("Status") {
            if let state = session.state {
                LabeledContent("State") {
                    HStack(spacing: 7) {
                        if state == .working {
                            SpinnerGlyph(active: true, frozen: freezeWorkingGlyphs)
                        }
                        Text(stateLabel(state: state.rawValue))
                            .foregroundStyle(.ccLabel)
                    }
                }
            }
            if let displayedElapsed {
                LabeledContent("Elapsed") {
                    Text(displayedElapsed)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.ccLabel)
                }
            }
            if let model = formattedModel {
                LabeledContent("Model", value: model)
            }
        }
    }

    @ViewBuilder
    private var contextSection: some View {
        Section("Context") {
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
    }

    @ViewBuilder
    private var usageSection: some View {
        Section("Usage") {
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
                    StatTile(value: formatTokenCount(messages), label: "Messages")
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var subagentsSection: some View {
        Section("Subagents") {
            ForEach(Array(sortedSubagents.enumerated()), id: \.offset) { _, subagent in
                Button { onSubagent(subagent) } label: {
                    HStack(spacing: 10) {
                        if subagent.state == .running {
                            SpinnerGlyph(active: true, frozen: freezeWorkingGlyphs)
                                .font(.subheadline)
                                .frame(width: 18)
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
                        if let elapsed = subagentElapsed(subagent) {
                            Text(elapsed)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.ccSecondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.ccSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(subagent.agentId == nil)
            }
        }
    }

    private var approvalsSection: some View {
        Section("Approvals") {
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

            if let selected = approvalModes.first(where: { $0.mode == currentMode }) {
                Text(selected.description)
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        Section("Location") {
            if let project = nonEmpty(session.project) {
                LabeledContent("Project", value: project)
            }
            if let branch = nonEmpty(branch) {
                LabeledContent("Branch", value: branch)
            }
            if let tmuxPane = nonEmpty(session.tmuxPane) {
                LabeledContent("tmux pane", value: tmuxPane)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section("Actions") {
            if session.tmuxPane != nil {
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
        }
    }

    private var displayedElapsed: String? {
        if let elapsed, !elapsed.isEmpty { return elapsed }
        let anchor = session.state == .working ? session.startedAt : session.idleSince
        guard let anchor else { return nil }
        return displayDuration(max(0, Int(anchor.distance(to: now) * 1000)))
    }

    private var formattedModel: String? {
        nonEmpty(formatModelName(usage?.model))
    }

    private func subagentElapsed(_ subagent: Subagent) -> String? {
        guard let started = subagent.startedAt else { return nil }
        let end = subagent.finishedAt ?? now
        return displayDuration(max(0, Int(started.distance(to: end) * 1000)))
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
