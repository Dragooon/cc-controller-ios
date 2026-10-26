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
    let activitySession: Session?
    let onActivity: () -> Void
    let slashCommands: [SlashCommand]
    let attachments: [ComposerAttachment]
    let attachmentNotice: String?
    let approvals: [Approval]
    let deciding: Set<String>
    let transcriptHeight: CGFloat
    let onSend: @MainActor @Sendable (String, Bool) async -> Result<MessageResult, ActionError>
    let onEnqueue: @MainActor @Sendable (String, Bool) async -> Result<QueuedNote, ActionError>
    let onAddAttachment: @MainActor @Sendable (UploadFile) -> Void
    let onRemoveAttachment: @MainActor @Sendable (String) -> Void
    let onRetryAttachment: @MainActor @Sendable (String) -> Void
    let onStop: @MainActor @Sendable () async -> Result<Void, ActionError>
    let onModel: @MainActor @Sendable () -> Void
    let onAllow: (Approval) -> Void
    let onAllowSession: (Approval) -> Void
    let onDeny: (Approval) -> Void
    let questionState: QuestionCardState?
    let canAnswerQuestions: Bool
    let onAnswer: (Approval, [String: String]) -> Void
    let onSkip: (Approval) -> Void
    /// The owning controller's name, set only when two or more controllers are paired.
    let approvalControllerName: String?
    let allowsSessionScope: Bool

    init(
        composer: ComposerConfiguration = ComposerConfiguration(),
        statusSegments: [String] = [],
        activitySession: Session? = nil,
        onActivity: @escaping () -> Void = {},
        slashCommands: [SlashCommand] = [],
        attachments: [ComposerAttachment] = [],
        attachmentNotice: String? = nil,
        approvals: [Approval] = [],
        deciding: Set<String> = [],
        transcriptHeight: CGFloat = 0,
        onSend: @escaping @MainActor @Sendable (String, Bool) async -> Result<MessageResult, ActionError> = { _, _ in .success(MessageResult()) },
        onEnqueue: @escaping @MainActor @Sendable (String, Bool) async -> Result<QueuedNote, ActionError> = { text, _ in .success(QueuedNote(text: text)) },
        onAddAttachment: @escaping @MainActor @Sendable (UploadFile) -> Void = { _ in },
        onRemoveAttachment: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onRetryAttachment: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onStop: @escaping @MainActor @Sendable () async -> Result<Void, ActionError> = { .success(()) },
        onModel: @escaping @MainActor @Sendable () -> Void = {},
        onAllow: @escaping (Approval) -> Void = { _ in },
        onAllowSession: @escaping (Approval) -> Void = { _ in },
        onDeny: @escaping (Approval) -> Void = { _ in },
        questionState: QuestionCardState? = nil,
        canAnswerQuestions: Bool = true,
        onAnswer: @escaping (Approval, [String: String]) -> Void = { _, _ in },
        onSkip: @escaping (Approval) -> Void = { _ in },
        approvalControllerName: String? = nil,
        allowsSessionScope: Bool = true
    ) {
        self.composer = composer
        self.statusSegments = statusSegments
        self.activitySession = activitySession
        self.onActivity = onActivity
        self.slashCommands = slashCommands
        self.attachments = attachments
        self.attachmentNotice = attachmentNotice
        self.approvals = approvals
        self.deciding = deciding
        self.transcriptHeight = transcriptHeight
        self.onSend = onSend
        self.onEnqueue = onEnqueue
        self.onAddAttachment = onAddAttachment
        self.onRemoveAttachment = onRemoveAttachment
        self.onRetryAttachment = onRetryAttachment
        self.onStop = onStop
        self.onModel = onModel
        self.onAllow = onAllow
        self.onAllowSession = onAllowSession
        self.onDeny = onDeny
        self.questionState = questionState
        self.canAnswerQuestions = canAnswerQuestions
        self.onAnswer = onAnswer
        self.onSkip = onSkip
        self.approvalControllerName = approvalControllerName
        self.allowsSessionScope = allowsSessionScope
    }

    func withTranscriptHeight(_ height: CGFloat) -> Self {
        Self(
            composer: composer,
            statusSegments: statusSegments,
            activitySession: activitySession,
            onActivity: onActivity,
            slashCommands: slashCommands,
            attachments: attachments,
            attachmentNotice: attachmentNotice,
            approvals: approvals,
            deciding: deciding,
            transcriptHeight: height,
            onSend: onSend,
            onEnqueue: onEnqueue,
            onAddAttachment: onAddAttachment,
            onRemoveAttachment: onRemoveAttachment,
            onRetryAttachment: onRetryAttachment,
            onStop: onStop,
            onModel: onModel,
            onAllow: onAllow,
            onAllowSession: onAllowSession,
            onDeny: onDeny,
            questionState: questionState,
            canAnswerQuestions: canAnswerQuestions,
            onAnswer: onAnswer,
            onSkip: onSkip,
            approvalControllerName: approvalControllerName,
            allowsSessionScope: allowsSessionScope
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
    @State private var pulseFailedAttachments = false
    @FocusState private var composerFocused: Bool
    @Namespace private var glassNamespace

    init(configuration: BottomStackConfiguration) {
        self.configuration = configuration
        _text = State(initialValue: configuration.composer.draft?.initialText() ?? configuration.composer.initialText)
    }

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.bottomStackBody)
        #endif
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if !filteredCommands.isEmpty {
                    SlashSuggestionsView(commands: filteredCommands) { command in
                        if command.command == "/model" {
                            text = ""
                            composerFocused = false
                            configuration.onModel()
                        } else {
                            text = "\(command.command) "
                            composerFocused = true
                        }
                    }
                }

                if !configuration.attachments.isEmpty {
                    AttachmentTrayView(
                        attachments: configuration.attachments,
                        notice: configuration.attachmentNotice,
                        pulseFailed: pulseFailedAttachments,
                        onRemove: configuration.onRemoveAttachment,
                        onRetry: configuration.onRetryAttachment
                    )
                } else if let notice = configuration.attachmentNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.ccSecondary)
                        .padding(.horizontal, 8)
                }

                if !configuration.approvals.isEmpty {
                    ApprovalBottomStackView(
                        approvals: configuration.approvals,
                        deciding: configuration.deciding,
                        maxHeight: max(0, configuration.transcriptHeight - 180),
                        onAllow: configuration.onAllow,
                        onAllowSession: configuration.onAllowSession,
                        onDeny: configuration.onDeny,
                        questionState: configuration.questionState,
                        canAnswerQuestions: configuration.canAnswerQuestions,
                        onAnswer: configuration.onAnswer,
                        onSkip: configuration.onSkip,
                        controllerName: configuration.approvalControllerName,
                        allowsSessionScope: configuration.allowsSessionScope,
                        glassNamespace: glassNamespace,
                        inGlassContainer: false
                    )
                }

                if !composerFocused, configuration.approvals.isEmpty, !configuration.statusSegments.isEmpty {
                    StatusLineView(
                        segments: configuration.statusSegments,
                        activitySession: configuration.activitySession,
                        onActivity: configuration.onActivity
                    )
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
                        onAddAttachment: configuration.onAddAttachment,
                        glassNamespace: glassNamespace,
                        resetGeneration: fieldResetGeneration
                    )
                    .equatable()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 0)
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
        .onChange(of: text) { _, newText in
            configuration.composer.draft?.onChange(newText)
        }
        .onChange(of: configuration.composer.draft?.revision) { _, _ in
            guard let draft = configuration.composer.draft else { return }
            text = draft.initialText()
            fieldResetGeneration += 1
        }
    }

    private var composerConfiguration: ComposerConfiguration {
        ComposerConfiguration(
            initialText: configuration.composer.initialText,
            modelName: configuration.composer.modelName,
            placeholder: configuration.composer.placeholder,
            isWorking: configuration.composer.isWorking,
            canInterrupt: configuration.composer.canInterrupt,
            focusesOnAppear: configuration.composer.focusesOnAppear,
            isSending: isSending,
            hasAttachments: !configuration.attachments.isEmpty
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
        let originalText = text
        let submittedText = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!submittedText.isEmpty || !configuration.attachments.isEmpty), !isSending else { return }
        if submittedText == "/model" && configuration.attachments.isEmpty {
            text = ""
            fieldResetGeneration += 1
            composerFocused = false
            configuration.onModel()
            return
        }
        if isSlashCommand(submittedText) {
            composerFocused = false
        }
        isSending = true
        Task { @MainActor in
            if isSlashCommand(submittedText) {
                let result = await configuration.onSend(submittedText, now)
                isSending = false
                switch result {
                case .success:
                    finishSuccessfulSend(originalText: originalText, submittedText: submittedText)
                case .failure(let error):
                    handleSendFailure(error)
                }
            } else {
                let result = await configuration.onEnqueue(submittedText, now)
                isSending = false
                switch result {
                case .success:
                    finishSuccessfulSend(originalText: originalText, submittedText: submittedText)
                case .failure(let error):
                    handleSendFailure(error)
                }
            }
        }
    }

    private func finishSuccessfulSend(originalText: String, submittedText: String) {
        if isSlashCommand(submittedText) {
            composerFocused = false
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let nextText = composerTextAfterSuccessfulSend(
                originalText: originalText,
                submittedText: submittedText,
                currentText: text
            ) {
                text = nextText
                fieldResetGeneration += 1
            }
        }
        sendFeedbackCount += 1
    }

    private func handleSendFailure(_ error: ActionError) {
        if case .invalid("Remove or retry the failed attachment") = error {
            pulseFailedAttachments = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                pulseFailedAttachments = false
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
