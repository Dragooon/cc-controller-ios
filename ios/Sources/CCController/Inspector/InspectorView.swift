import CCKit
import SwiftUI

struct InspectorView: View {
    let session: Session
    let elapsed: String
    let branch: String
    let freezeWorkingGlyphs: Bool
    let onInterrupt: () -> Void
    let onCopySessionID: () -> Void
    let onApprovalMode: (ApprovalMode) -> Void

    private let approvalModes: [(mode: ApprovalMode, title: String, description: String)] = [
        (.auto, "Auto", "Ask in the terminal when it's open on the Mac, otherwise on this iPhone."),
        (.remote, "Remote", "Ask on this iPhone first. After about 10 minutes the terminal takes over."),
        (.terminal, "Terminal", "Always ask in the Mac's terminal."),
    ]

    private var usage: Usage { session.usage ?? Usage() }
    private var contextPercent: Double { min(max(usage.contextPercent ?? 0, 0), 100) }
    private var runningSubagents: [Subagent] {
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
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("State") {
                HStack(spacing: 7) {
                    SpinnerGlyph(active: true, frozen: freezeWorkingGlyphs)
                    Text("Working")
                        .foregroundStyle(.ccLabel)
                }
            }
            LabeledContent("Elapsed") {
                Text(elapsed)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.ccLabel)
            }
            LabeledContent("Model") {
                Text(formatModelName(usage.model))
                    .foregroundStyle(.ccLabel)
            }
        }
    }

    private var contextSection: some View {
        Section("Context") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    Gauge(value: contextPercent / 100, in: 0...1) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .gaugeStyle(.linearCapacity)
                    .tint(.ccAccent)
                    .frame(maxWidth: .infinity)

                    Text("\(Int(contextPercent.rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.ccLabel)
                }

                Text("\(formatTokenCount(usage.contextTokens)) of \(formatTokenCount(usage.contextWindow)) tokens")
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
            }
        }
    }

    private var usageSection: some View {
        Section("Usage") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(value: "3.1M", label: "Input")
                StatTile(value: "84k", label: "Output")
                StatTile(value: "92%", label: "Cache")
                StatTile(value: "214", label: "Messages")
            }
            .padding(.vertical, 2)
        }
    }

    private var subagentsSection: some View {
        Section("Subagents") {
            ForEach(Array(runningSubagents.enumerated()), id: \.offset) { _, subagent in
                Button(action: {}) {
                    HStack(spacing: 10) {
                        if subagent.state == .running {
                            SpinnerGlyph(active: true, frozen: freezeWorkingGlyphs)
                                .font(.subheadline)
                                .frame(width: 18)
                        } else {
                            Circle()
                                .fill(.ccGreen)
                                .frame(width: 8, height: 8)
                                .frame(width: 18)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(subagent.agent ?? "agent")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.ccLabel)
                            Text(subagent.text ?? "Working on the task")
                                .font(.footnote)
                                .foregroundStyle(.ccSecondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Text(subagent.state == .running ? "3m" : "18m")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.ccSecondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.ccSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var approvalsSection: some View {
        Section("Approvals") {
            ForEach(approvalModes, id: \.mode.rawValue) { choice in
                Button {
                    onApprovalMode(choice.mode)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.ccLabel)
                            Text(choice.description)
                                .font(.footnote)
                                .foregroundStyle(.ccSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if session.mode == choice.mode {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.ccAccent)
                                .accessibilityLabel("Selected")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var locationSection: some View {
        Section("Location") {
            LabeledContent("Project", value: session.project ?? "atlas")
            LabeledContent("Branch", value: branch)
            LabeledContent("tmux pane", value: session.tmuxPane ?? "control:2.1")
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button(role: .destructive, action: onInterrupt) {
                Label("Interrupt", systemImage: "stop.circle")
            }
            .disabled(session.tmuxPane == nil && session.tmux == false)
            .accessibilityHint("Stops the current turn in the terminal pane")

            Button(action: onCopySessionID) {
                Label("Copy session ID", systemImage: "doc.on.doc")
            }
        }
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
