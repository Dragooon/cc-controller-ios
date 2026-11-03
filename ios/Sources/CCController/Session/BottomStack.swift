import CCKit
import SwiftUI

@MainActor
final class SendRevealCoordinator {
    private var revealContinuation: AsyncStream<Void>.Continuation?
    private var revealStream: AsyncStream<Void>?
    private(set) var isWaiting = false
    private var contentHeightChanged = false
    private var revealCompleted = false

    func begin() {
        let stream = AsyncStream<Void> { continuation in
            revealContinuation = continuation
        }
        revealStream = stream
        isWaiting = true
        contentHeightChanged = false
        revealCompleted = false
    }

    func cancel() {
        revealContinuation?.finish()
        revealContinuation = nil
        revealStream = nil
        isWaiting = false
        contentHeightChanged = false
        revealCompleted = false
    }

    func observeContentHeightChange() {
        guard isWaiting else { return }
        contentHeightChanged = true
    }

    func completeIfReady(isAtBottom: Bool) -> Bool {
        guard isWaiting, contentHeightChanged, isAtBottom, !revealCompleted else { return false }
        revealCompleted = true
        revealContinuation?.yield()
        revealContinuation?.finish()
        return true
    }

    func waitForReveal(timeout: Duration = .milliseconds(100)) async {
        guard isWaiting else { return }
        if !revealCompleted, let revealStream {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in revealStream { break }
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                }
                _ = await group.next()
                group.cancelAll()
            }
        }
        cancel()
    }
}

/// Whether the software keyboard is on screen, so work can wait for it to leave.
@MainActor
final class KeyboardPresence {
    static let shared = KeyboardPresence()

    private var isVisible = false
    private var lastHide: (duration: TimeInterval, curve: UInt, startedAt: CFTimeInterval)?

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = true }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] notification in
            let info = notification.userInfo
            let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
            let curve = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
            MainActor.assumeIsolated { self?.lastHide = (duration, curve, CACurrentMediaTime()) }
        }
        center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = false }
        }
    }

    func start() {}

    /// The keyboard's own timing when it has just started hiding, so something moving with it can match it exactly.
    func hideStartedJustNow() -> (duration: TimeInterval, options: UIView.AnimationOptions)? {
        guard let lastHide, lastHide.duration > 0, CACurrentMediaTime() - lastHide.startedAt < 0.15 else { return nil }
        return (lastHide.duration, UIView.AnimationOptions(rawValue: lastHide.curve << 16))
    }

    /// Returns at once with no keyboard up. The timeout covers a keyboard that gets refocused on its way down.
    func waitUntilHidden(timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while isVisible, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}

struct SlashCommand: Identifiable {
    let command: String
    let description: String

    var id: String { command }
}

struct BottomStackConfiguration: @unchecked Sendable {
    let sessionID: String?
    let sendRevealCoordinator: SendRevealCoordinator?
    let composer: ComposerConfiguration
    let waking: Bool
    let wakeError: String?
    let onRetryWake: () -> Void
    let slashCommands: [SlashCommand]
    let attachments: [ComposerAttachment]
    let attachmentNotice: String?
    let approvals: [Approval]
    let deciding: Set<String>
    let availableHeight: CGFloat
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
    let terminalPaneAvailable: Bool
    let approvalAttachCommand: String?
    /// Set on sessions the app may only read, such as "Read-only · Discord". It replaces the composer.
    let readOnlyLabel: String?

    init(
        sessionID: String? = nil,
        sendRevealCoordinator: SendRevealCoordinator? = nil,
        composer: ComposerConfiguration = ComposerConfiguration(),
        waking: Bool = false,
        wakeError: String? = nil,
        onRetryWake: @escaping () -> Void = {},
        slashCommands: [SlashCommand] = [],
        attachments: [ComposerAttachment] = [],
        attachmentNotice: String? = nil,
        approvals: [Approval] = [],
        deciding: Set<String> = [],
        availableHeight: CGFloat = 0,
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
        allowsSessionScope: Bool = true,
        terminalPaneAvailable: Bool = true,
        approvalAttachCommand: String? = nil,
        readOnlyLabel: String? = nil
    ) {
        self.sessionID = sessionID
        self.sendRevealCoordinator = sendRevealCoordinator
        self.composer = composer
        self.waking = waking
        self.wakeError = wakeError
        self.onRetryWake = onRetryWake
        self.slashCommands = slashCommands
        self.attachments = attachments
        self.attachmentNotice = attachmentNotice
        self.approvals = approvals
        self.deciding = deciding
        self.availableHeight = availableHeight
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
        self.terminalPaneAvailable = terminalPaneAvailable
        self.approvalAttachCommand = approvalAttachCommand
        self.readOnlyLabel = readOnlyLabel
    }

    func withAvailableHeight(_ height: CGFloat) -> Self {
        Self(
            sessionID: sessionID,
            sendRevealCoordinator: sendRevealCoordinator,
            composer: composer,
            waking: waking,
            wakeError: wakeError,
            onRetryWake: onRetryWake,
            slashCommands: slashCommands,
            attachments: attachments,
            attachmentNotice: attachmentNotice,
            approvals: approvals,
            deciding: deciding,
            availableHeight: height,
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
            allowsSessionScope: allowsSessionScope,
            terminalPaneAvailable: terminalPaneAvailable,
            approvalAttachCommand: approvalAttachCommand,
            readOnlyLabel: readOnlyLabel
        )
    }
}

struct BottomStackView: View {
    let configuration: BottomStackConfiguration
    @State private var text: String
    @State private var isSending = false
    @State private var fieldResetGeneration = 0
    @State private var fieldResetRestoresFocus = true
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
            VStack(alignment: .leading, spacing: 6) {
                if !filteredCommands.isEmpty {
                    SlashSuggestionsView(commands: filteredCommands) { command in
                        switch slashSuggestionAction(command: command.command) {
                        case .openModelSheet:
                            text = ""
                            composerFocused = false
                            configuration.onModel()
                        case .fillComposer(let filled):
                            text = filled
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
                        maxHeight: max(160, configuration.availableHeight * 0.35),
                        onAllow: configuration.onAllow,
                        onAllowSession: configuration.onAllowSession,
                        onDeny: configuration.onDeny,
                        questionState: configuration.questionState,
                        canAnswerQuestions: configuration.canAnswerQuestions,
                        onAnswer: configuration.onAnswer,
                        onSkip: configuration.onSkip,
                        controllerName: configuration.approvalControllerName,
                        allowsSessionScope: configuration.allowsSessionScope,
                        terminalPaneAvailable: configuration.terminalPaneAvailable,
                        attachCommand: configuration.approvalAttachCommand,
                        glassNamespace: glassNamespace,
                        inGlassContainer: false
                    )
                }

                if configuration.approvals.isEmpty, configuration.waking {
                    WakeStatusLine()
                        .transition(.opacity)
                }

                if configuration.approvals.isEmpty, let wakeError = configuration.wakeError {
                    WakeErrorBanner(message: wakeError, onRetry: configuration.onRetryWake)
                }

                if configuration.approvals.isEmpty, let readOnlyLabel = configuration.readOnlyLabel {
                    ReadOnlyBar(label: readOnlyLabel)
                } else if configuration.approvals.isEmpty {
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
                        resetGeneration: fieldResetGeneration,
                        restoresFocusOnReset: fieldResetRestoresFocus
                    )
                    .equatable()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 0)
            .padding(.bottom, 4)
        }
        #if DEBUG
        .task { await runMotionAutoSendIfAsked() }
        #endif
        .onAppear { KeyboardPresence.shared.start() }
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
            fieldResetRestoresFocus = true
            fieldResetGeneration += 1
        }
    }

    private var composerConfiguration: ComposerConfiguration {
        ComposerConfiguration(
            initialText: configuration.composer.initialText,
            modelName: configuration.composer.modelName,
            placeholder: configuration.composer.placeholder,
            isWorking: configuration.composer.isWorking,
            canSend: configuration.composer.canSend,
            canInterrupt: configuration.composer.canInterrupt,
            canAttach: configuration.composer.canAttach,
            canRunCommands: configuration.composer.canRunCommands,
            focusesOnAppear: configuration.composer.focusesOnAppear,
            isSending: isSending,
            hasAttachments: !configuration.attachments.isEmpty
        )
    }

    private var filteredCommands: [SlashCommand] {
        slashSuggestions(text: text, commands: configuration.slashCommands, name: \.command)
    }

    private func send() {
        submit(now: false)
    }

    private func sendNow() {
        submit(now: true)
    }

    #if DEBUG
    /// Sends from inside the app, for a motion trace free of XCUITest's work on the main thread.
    private func runMotionAutoSendIfAsked() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CCMotionAutoSend"), arguments.count > index + 1 else { return }
        try? await Task.sleep(for: .seconds(20))
        composerFocused = true
        try? await Task.sleep(for: .seconds(2))
        text = arguments[index + 1]
        try? await Task.sleep(for: .seconds(2))
        MotionTrace.shared.touchSampleTrigger()
        try? await Task.sleep(for: .milliseconds(600))
        submit(now: false)
    }
    #endif

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
        #if DEBUG
        recordLifecycleEvent(name: "send-tap", sessionID: configuration.sessionID)
        MotionTrace.shared.recordEvent("sendTapped", data: ["noteID": submittedText])
        #endif
        if !isSlashCommand(submittedText) {
            configuration.sendRevealCoordinator?.begin()
            // Resigning here rather than on the next update commits any autocorrection into the text
            // before it's read, so everything can happen on the tap.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            composerFocused = false
        }
        let committedText = text
        let committedTrimmedText = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let textToSend = committedTrimmedText.isEmpty ? submittedText : committedTrimmedText
        // A send with attachments may wait on uploads, so it keeps its text until then.
        if !isSlashCommand(submittedText), configuration.attachments.isEmpty {
            clearComposerAfterSend(originalText: committedText, submittedText: textToSend)
        }
        isSending = true
        // Runs up to its first suspension right here, so the note lands in the same commit as the keyboard hiding
        // and the two start together. The transcript only moves one way when they do.
        Task.immediate { @MainActor in
            #if DEBUG
            recordLifecycleEvent(name: "send-task-start", sessionID: configuration.sessionID)
            #endif
            if isSlashCommand(submittedText) {
                let result = await configuration.onSend(submittedText, now)
                isSending = false
                switch result {
                case .success:
                    await finishSuccessfulSend(originalText: originalText, submittedText: submittedText)
                case .failure(let error):
                    configuration.sendRevealCoordinator?.cancel()
                    handleSendFailure(error)
                }
            } else {
                let result = await configuration.onEnqueue(textToSend, now)
                isSending = false
                switch result {
                case .success:
                    await finishSuccessfulSend(originalText: committedText, submittedText: textToSend)
                    await clearTextWrittenBackAfterSend()
                case .failure(let error):
                    configuration.sendRevealCoordinator?.cancel()
                    if text.isEmpty {
                        text = originalText
                    }
                    handleSendFailure(error)
                }
            }
        }
    }

    /// A slow focus change can write the sent text back after it was cleared. Once the keyboard has gone,
    /// anything left in an unfocused composer is that, since nobody could have typed it.
    private func clearTextWrittenBackAfterSend() async {
        await KeyboardPresence.shared.waitUntilHidden(timeout: .milliseconds(700))
        guard !composerFocused, !text.isEmpty else { return }
        text = ""
        fieldResetRestoresFocus = false
        fieldResetGeneration += 1
    }

    private func finishSuccessfulSend(originalText: String, submittedText: String) async {
        #if DEBUG
        recordLifecycleEvent(name: "send-focus-drop", sessionID: configuration.sessionID)
        #endif
        composerFocused = false
        clearComposerAfterSend(originalText: originalText, submittedText: submittedText)
        if !isSlashCommand(submittedText) {
            await configuration.sendRevealCoordinator?.waitForReveal()
        }
        sendFeedbackCount += 1
    }

    // No animation of its own: this runs in the same update as the keyboard starting to hide, and an
    // animation here would also carry the keyboard's safe-area change, moving the composer off the keyboard's curve.
    private func clearComposerAfterSend(originalText: String, submittedText: String) {
        if let nextText = composerTextAfterSuccessfulSend(
            originalText: originalText,
            submittedText: submittedText,
            currentText: text
        ) {
            text = nextText
            #if DEBUG
            MotionTrace.shared.recordComposerCleared()
            #endif
            fieldResetRestoresFocus = false
            fieldResetGeneration += 1
        }
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

private struct WakeStatusLine: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Waking…")
        }
        .font(.caption)
        .foregroundStyle(.ccTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session-waking")
    }
}

private struct WakeErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.ccRed)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: onRetry)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.ccAccent)
                .accessibilityIdentifier("wake-retry")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ccRed.opacity(0.12), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wake-error")
    }
}

/// Takes the composer's place on a session the app may only read.
private struct ReadOnlyBar: View {
    let label: String

    var body: some View {
        Label(label, systemImage: "lock")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.ccSecondary)
            .frame(maxWidth: .infinity, minHeight: CCMetrics.minTap)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("read-only-bar")
            .accessibilityLabel(label)
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
