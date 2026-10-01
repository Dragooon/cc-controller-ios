import CCKit
import SwiftUI

struct SlashCommand: Identifiable {
    let command: String
    let description: String

    var id: String { command }
}

struct BottomStackConfiguration: @unchecked Sendable {
    let composer: ComposerConfiguration
    let statusSegments: [String]
    let slashCommands: [SlashCommand]
    let attachments: [ComposerAttachment]
    let approvals: [Approval]
    let deciding: Set<String>
    let transcriptHeight: CGFloat
    let onSend: @MainActor @Sendable (String, Bool) async -> Result<Void, ActionError>
    let onStop: @MainActor @Sendable () async -> Result<Void, ActionError>
    let onModel: @MainActor @Sendable () -> Void
    let onAllow: (Approval) -> Void
    let onAllowSession: (Approval) -> Void
    let onDeny: (Approval) -> Void

    init(
        composer: ComposerConfiguration = ComposerConfiguration(),
        statusSegments: [String] = [],
        slashCommands: [SlashCommand] = [],
        attachments: [ComposerAttachment] = [],
        approvals: [Approval] = [],
        deciding: Set<String> = [],
        transcriptHeight: CGFloat = 0,
        onSend: @escaping @MainActor @Sendable (String, Bool) async -> Result<Void, ActionError> = { _, _ in .success(()) },
        onStop: @escaping @MainActor @Sendable () async -> Result<Void, ActionError> = { .success(()) },
        onModel: @escaping @MainActor @Sendable () -> Void = {},
        onAllow: @escaping (Approval) -> Void = { _ in },
        onAllowSession: @escaping (Approval) -> Void = { _ in },
        onDeny: @escaping (Approval) -> Void = { _ in }
    ) {
        self.composer = composer
        self.statusSegments = statusSegments
        self.slashCommands = slashCommands
        self.attachments = attachments
        self.approvals = approvals
        self.deciding = deciding
        self.transcriptHeight = transcriptHeight
        self.onSend = onSend
        self.onStop = onStop
        self.onModel = onModel
        self.onAllow = onAllow
        self.onAllowSession = onAllowSession
        self.onDeny = onDeny
    }

    func withTranscriptHeight(_ height: CGFloat) -> Self {
        Self(
            composer: composer,
            statusSegments: statusSegments,
            slashCommands: slashCommands,
            attachments: attachments,
            approvals: approvals,
            deciding: deciding,
            transcriptHeight: height,
            onSend: onSend,
            onStop: onStop,
            onModel: onModel,
            onAllow: onAllow,
            onAllowSession: onAllowSession,
            onDeny: onDeny
        )
    }
}

struct BottomStackView: View {
    let configuration: BottomStackConfiguration
    @State private var text: String
    @State private var isSending = false
    @State private var fieldResetGeneration = 0
    @State private var sendFeedbackCount = 0
    @State private var stopFeedbackCount = 0
    @FocusState private var composerFocused: Bool
    @Namespace private var glassNamespace

    init(configuration: BottomStackConfiguration) {
        self.configuration = configuration
        _text = State(initialValue: configuration.composer.initialText)
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if !filteredCommands.isEmpty {
                    SlashSuggestionsView(commands: filteredCommands) { command in
                        text = "\(command.command) "
                        composerFocused = true
                    }
                }

                if !configuration.attachments.isEmpty {
                    AttachmentTrayView(attachments: configuration.attachments)
                }

                if !configuration.approvals.isEmpty {
                    ApprovalBottomStackView(
                        approvals: configuration.approvals,
                        deciding: configuration.deciding,
                        maxHeight: max(0, configuration.transcriptHeight - 180),
                        onAllow: configuration.onAllow,
                        onAllowSession: configuration.onAllowSession,
                        onDeny: configuration.onDeny,
                        glassNamespace: glassNamespace,
                        inGlassContainer: false
                    )
                }

                if !composerFocused, configuration.approvals.isEmpty, !configuration.statusSegments.isEmpty {
                    StatusLineView(segments: configuration.statusSegments)
                        .transition(.opacity)
                }

                if configuration.approvals.isEmpty {
                    ComposerView(
                        text: $text,
                        isFocused: $composerFocused,
                        configuration: composerConfiguration,
                        onModel: configuration.onModel,
                        onStop: stop,
                        onSend: send,
                        onSendNow: sendNow,
                        glassNamespace: glassNamespace,
                        resetGeneration: fieldResetGeneration
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .background(.ccBackground.opacity(0.88))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bottom-stack")
        .sensoryFeedback(.impact(weight: .light), trigger: sendFeedbackCount)
        .sensoryFeedback(.impact(weight: .light), trigger: stopFeedbackCount)
        .onAppear {
            guard configuration.composer.focusesOnAppear else { return }
            DispatchQueue.main.async {
                composerFocused = true
            }
        }
    }

    private var composerConfiguration: ComposerConfiguration {
        ComposerConfiguration(
            initialText: configuration.composer.initialText,
            modelName: configuration.composer.modelName,
            placeholder: configuration.composer.placeholder,
            isWorking: configuration.composer.isWorking,
            hasTmuxPane: configuration.composer.hasTmuxPane,
            focusesOnAppear: configuration.composer.focusesOnAppear,
            isSending: isSending
        )
    }

    private var filteredCommands: [SlashCommand] {
        guard text.hasPrefix("/") else { return [] }
        let prefix = text.split(whereSeparator: \ .isWhitespace).first.map(String.init) ?? text
        return configuration.slashCommands.filter { $0.command.lowercased().hasPrefix(prefix.lowercased()) }
    }

    private func send() {
        submit(now: false)
    }

    private func sendNow() {
        submit(now: true)
    }

    private func submit(now: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        Task { @MainActor in
            let result = await configuration.onSend(trimmed, now)
            isSending = false
            switch result {
            case .success:
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    text = ""
                    fieldResetGeneration += 1
                }
                sendFeedbackCount += 1
            case .failure:
                break
            }
        }
    }

    private func stop() {
        stopFeedbackCount += 1
        Task { @MainActor in
            _ = await configuration.onStop()
        }
    }
}

private struct SlashSuggestionsView: View {
    let commands: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(commands) { command in
                    Button { onSelect(command) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.command)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.ccLabel)
                            Text(command.description)
                                .font(.caption)
                                .foregroundStyle(.ccSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .accessibilityLabel("\(command.command), \(command.description)")
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
    }
}
