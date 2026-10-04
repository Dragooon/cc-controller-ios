import CCKit
import SwiftUI
import UIKit

struct SubagentResultSheet: View {
    let entry: SubagentResultEntry
    let subagent: Subagent?
    let onViewTranscript: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var agent: String { entry.agent ?? subagent?.agent ?? "agent" }
    private var taskDescription: String { subagent?.text ?? entry.text ?? "" }
    private var result: String { entry.result ?? entry.text ?? "" }
    private var state: SubagentState { entry.state ?? subagent?.state ?? .done }
    private var durationText: String { displayDuration(durationMilliseconds) }

    private var linkedTranscript: Bool {
        let agentID = subagent?.agentId ?? entry.agentId
        return agentID?.isEmpty == false && subagent?.linked != false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    Divider().overlay(.ccSeparator)
                    MarkdownView(markdown: result.isEmpty ? "No result." : result)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom, spacing: 12) {
                if linkedTranscript {
                    Button {
                        dismiss()
                        onViewTranscript()
                    } label: {
                        Label("View transcript", systemImage: "text.bubble")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: CCMetrics.actionHeight)
                            .contentShape(Rectangle())
                            .glassEffect(.regular.tint(.ccAccent).interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("subagent-view-transcript")
                    .padding(.horizontal, 20)
                }
            }
            .background(.ccBackground)
            .navigationTitle("\(agent) result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", role: .close) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = result
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("subagent-result-copy")
                }
            }
        }
        .tint(.ccAccent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(agent)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.ccLabel)

            if !taskDescription.isEmpty {
                Text(taskDescription)
                    .font(.subheadline)
                    .foregroundStyle(.ccSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: stateSymbol)
                    .foregroundStyle(stateColor)
                    .accessibilityHidden(true)
                Text(stateLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stateColor)
                Spacer(minLength: 8)
                Text(durationText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.ccSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var durationMilliseconds: Int {
        if let durationMs = entry.durationMs { return durationMs }
        guard let startedAt = subagent?.startedAt, let finishedAt = subagent?.finishedAt else { return 0 }
        return max(0, Int(startedAt.distance(to: finishedAt) * 1000))
    }

    private var stateLabel: String {
        switch state {
        case .done: "Replied"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .running: "Running"
        case .unknown(let value): value.capitalized
        }
    }

    private var stateSymbol: String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .stopped, .unknown: "stop.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        }
    }

    private var stateColor: Color {
        switch state {
        case .done: .ccGreen
        case .failed: .ccRed
        case .stopped, .unknown, .running: .ccSecondary
        }
    }
}
