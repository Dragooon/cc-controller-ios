import AVFoundation
import CCKit
import OSLog
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ComposerDraft {
    let initialText: @MainActor () -> String
    let revision: Int
    let onChange: @MainActor (String) -> Void

    init(
        initialText: @escaping @MainActor () -> String,
        revision: Int = 0,
        onChange: @escaping @MainActor (String) -> Void
    ) {
        self.initialText = initialText
        self.revision = revision
        self.onChange = onChange
    }
}

struct ComposerConfiguration: Equatable {
    let initialText: String
    let draft: ComposerDraft?
    let modelName: String?
    /// The session's effort level, shown after the model. Nil when the controller doesn't report one.
    let effortName: String?
    let placeholder: String
    let isWorking: Bool
    let canSend: Bool
    let canInterrupt: Bool
    /// False when the owning controller does not advertise `files`.
    let canAttach: Bool
    /// False when the owning controller does not advertise `commands`; hides the model chip.
    let canRunCommands: Bool
    let focusesOnAppear: Bool
    var isSending: Bool
    var hasAttachments: Bool
    /// The host speaks, so an empty composer offers voice mode where send sits.
    let offersVoice: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modelName == rhs.modelName
            && lhs.effortName == rhs.effortName
            && lhs.placeholder == rhs.placeholder
            && lhs.isWorking == rhs.isWorking
            && lhs.canSend == rhs.canSend
            && lhs.canInterrupt == rhs.canInterrupt
            && lhs.canAttach == rhs.canAttach
            && lhs.canRunCommands == rhs.canRunCommands
            && lhs.isSending == rhs.isSending
            && lhs.hasAttachments == rhs.hasAttachments
            && lhs.offersVoice == rhs.offersVoice
    }

    init(
        initialText: String = "",
        draft: ComposerDraft? = nil,
        modelName: String? = "Fable 5.1",
        effortName: String? = nil,
        placeholder: String = "Message",
        isWorking: Bool = false,
        canSend: Bool = true,
        canInterrupt: Bool = false,
        canAttach: Bool = true,
        canRunCommands: Bool = true,
        focusesOnAppear: Bool = false,
        isSending: Bool = false,
        hasAttachments: Bool = false,
        offersVoice: Bool = false
    ) {
        self.initialText = initialText
        self.draft = draft
        self.modelName = modelName
        self.effortName = effortName
        self.placeholder = placeholder
        self.isWorking = isWorking
        self.canSend = canSend
        self.canInterrupt = canInterrupt
        self.canAttach = canAttach
        self.canRunCommands = canRunCommands
        self.focusesOnAppear = focusesOnAppear
        self.isSending = isSending
        self.hasAttachments = hasAttachments
        self.offersVoice = offersVoice
    }
}

private struct OpenInspectorActionKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
    var openInspector: @MainActor @Sendable () -> Void {
        get { self[OpenInspectorActionKey.self] }
        set { self[OpenInspectorActionKey.self] = newValue }
    }
}

private struct OpenFilePreviewActionKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (URL) -> Void = { _ in }
}

extension EnvironmentValues {
    var openFilePreview: @MainActor @Sendable (URL) -> Void {
        get { self[OpenFilePreviewActionKey.self] }
        set { self[OpenFilePreviewActionKey.self] = newValue }
    }
}

struct ComposerView: View, Equatable {
    @Binding private var text: String
    @FocusState.Binding private var isFocused: Bool
    let configuration: ComposerConfiguration
    let onModel: () -> Void
    let onStop: () -> Void
    let onSend: () -> Void
    let onSendNow: () -> Void
    let onVoice: () -> Void
    let onAddAttachment: @MainActor @Sendable (UploadFile) -> Void
    let glassNamespace: Namespace.ID?
    let resetGeneration: Int
    let restoresFocusOnReset: Bool
    /// Focused or holding a draft. The owner passes it in, because this view is equatable and focus changes alone
    /// don't redraw it.
    let isInUse: Bool

    @State private var fieldGeneration = 0
    @State private var attachmentRequest: AttachmentSource?
    @State private var restoreFocus = false
    private let focusLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc-controller", category: "composer")
    @ScaledMetric(relativeTo: .body) private var circleSize = CCMetrics.controlCircle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var chipHeight = CCMetrics.chipHeight

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration
            && lhs.resetGeneration == rhs.resetGeneration
            && lhs.restoresFocusOnReset == rhs.restoresFocusOnReset
            && lhs.isInUse == rhs.isInUse
    }

    init(
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        configuration: ComposerConfiguration,
        onModel: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onSend: @escaping () -> Void = {},
        onSendNow: @escaping () -> Void = {},
        onVoice: @escaping () -> Void = {},
        onAddAttachment: @escaping @MainActor @Sendable (UploadFile) -> Void = { _ in },
        glassNamespace: Namespace.ID? = nil,
        resetGeneration: Int = 0,
        restoresFocusOnReset: Bool = true,
        isInUse: Bool = true
    ) {
        _text = text
        _isFocused = isFocused
        self.configuration = configuration
        self.onModel = onModel
        self.onStop = onStop
        self.onSend = onSend
        self.onSendNow = onSendNow
        self.onVoice = onVoice
        self.onAddAttachment = onAddAttachment
        self.glassNamespace = glassNamespace
        self.resetGeneration = resetGeneration
        self.restoresFocusOnReset = restoresFocusOnReset
        self.isInUse = isInUse
    }

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.composerBody)
        #endif
        bodyContent
            .modifier(AttachmentPickers(request: $attachmentRequest, onAdd: onAddAttachment))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Message composer")
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let glassNamespace {
            composerLayout.glassEffectID("composer", in: glassNamespace)
        } else {
            composerLayout
        }
    }

    /// Empty and not in use: one row, like the system and Claude apps, so the transcript gets the space back. Tapping
    /// in, a draft or an attachment brings back the full composer with the model chip.
    private var isCompact: Bool {
        !isInUse && !configuration.hasAttachments
    }

    /// One custom layout for both states, so every control keeps its identity: the buttons stay in the bottom row and
    /// the field moves between that row and its own line above. Focusing the field switches the layout without
    /// rebuilding it (which would drop the keyboard), and the owner's spring moves everything to its new place.
    private var composerLayout: some View {
        ComposerRowsLayout(isCompact: isCompact) {
            if configuration.canAttach {
                attachmentMenu
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .layoutValue(key: ComposerSlotKey.self, value: .leading)
            }
            messageField
                .layoutValue(key: ComposerSlotKey.self, value: .field)
            if !isCompact, configuration.modelName != nil, configuration.canRunCommands {
                modelButton
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    // Grows out from beside the attach button as the field moves up; no fade.
                    .transition(.scale(scale: 0.01, anchor: .leading))
                    .layoutValue(key: ComposerSlotKey.self, value: .leading)
            }
            if configuration.isWorking, configuration.canInterrupt {
                stopButton
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .layoutValue(key: ComposerSlotKey.self, value: .trailing)
            }
            sendButton
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .layoutValue(key: ComposerSlotKey.self, value: .trailing)
        }
        .padding(ComposerRowsLayout.cardInset)
        .glassEffect(.regular, in: .rect(cornerRadius: ComposerRowsLayout.cornerRadius))
        .onChange(of: resetGeneration) { _, generation in
            restoreFocus = restoresFocusOnReset && isFocused
            fieldGeneration = generation
        }
    }

    private var messageField: some View {
        TextField(configuration.placeholder, text: $text, axis: .vertical)
            .font(.body)
            .foregroundStyle(.ccLabel)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .transition(.identity)
            .id(fieldGeneration)
            .task(id: fieldGeneration) {
                guard restoreFocus else { return }
                isFocused = true
                var consecutiveFocusedChecks = 0
                for _ in 0..<10 {
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    if isFocused {
                        consecutiveFocusedChecks += 1
                    } else {
                        consecutiveFocusedChecks = 0
                        isFocused = true
                    }
                    if consecutiveFocusedChecks == 2 {
                        restoreFocus = false
                        return
                    }
                }
                restoreFocus = false
                focusLogger.error("composer focus restoration did not stick")
            }
            .accessibilityIdentifier("composer-text")
    }

    private var attachmentMenu: some View {
        Menu {
            AttachmentSourceButtons { attachmentRequest = $0 }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: visibleCircleSize, height: visibleCircleSize)
                .glassEffect(.regular.interactive(), in: .circle)
                .tapOutset(horizontal: 4, vertical: 4)
        }
        .buttonStyle(.plain)
        .frame(width: CCMetrics.minTap, height: CCMetrics.minTap)
        .contentShape(Rectangle())
        .accessibilityLabel("Add attachment")
    }

    @ViewBuilder
    private var modelButton: some View {
        if let modelName = configuration.modelName {
            Button(action: onModel) {
                modelChipText(modelName)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 11)
                    .frame(height: visibleChipHeight)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .tapOutset(vertical: 7)
            }
            .buttonStyle(.plain)
            .frame(minWidth: CCMetrics.minTap, minHeight: CCMetrics.minTap)
            .layoutPriority(-1)
            .contentShape(Rectangle())
            .accessibilityLabel(configuration.effortName.map { "Model \(modelName), effort \($0)" } ?? "Model \(modelName)")
            .accessibilityIdentifier("composer-model")
        }
    }

    /// The model, then the effort level in the quieter colour: "Fable 5.2 Extra".
    private func modelChipText(_ modelName: String) -> Text {
        let model = Text(modelName).foregroundStyle(.ccLabel)
        guard let effortName = configuration.effortName else { return model }
        return model + Text(" \(effortName)").foregroundStyle(.ccSecondary)
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.body.weight(.semibold))
                .frame(width: visibleCircleSize, height: visibleCircleSize)
                .foregroundStyle(.ccLabel)
                .glassEffect(.regular.interactive(), in: .circle)
                .tapOutset(horizontal: 4, vertical: 4)
        }
        .buttonStyle(.plain)
        .frame(width: CCMetrics.minTap, height: CCMetrics.minTap)
        .contentShape(Rectangle())
        .accessibilityLabel("Stop session")
        .accessibilityIdentifier("composer-stop")
    }

    /// Empty, with nothing attached and a host that speaks: the button where send sits starts voice mode, as in the
    /// Claude app. Typing or attaching turns it into send (queue while a turn runs), the symbol changing in place.
    private var offersVoiceNow: Bool {
        configuration.offersVoice && configuration.canSend && !configuration.isSending && !configuration.hasAttachments
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButton: some View {
        let voice = offersVoiceNow
        return Button(action: voice ? onVoice : onSend) {
            Group {
                if configuration.isSending {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                } else {
                    Image(systemName: voice ? "waveform" : "arrow.up")
                        .font(.body.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .animation(CCMotion.quick(reduceMotion: reduceMotion), value: voice)
                }
            }
            .frame(width: visibleCircleSize, height: visibleCircleSize)
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(.ccAccent).interactive(), in: .circle)
            .tapOutset(horizontal: 4, vertical: 4)
        }
        .buttonStyle(.plain)
        .frame(width: CCMetrics.minTap, height: CCMetrics.minTap)
        .contentShape(Rectangle())
        .disabled(!voice && (!configuration.canSend || configuration.isSending || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !configuration.hasAttachments)))
        .accessibilityLabel(voice ? "Start voice mode" : configuration.isWorking ? "Queue message" : "Send message")
        .accessibilityIdentifier(voice ? "voice-mode-button" : configuration.isWorking ? "composer-queue" : "composer-send")
        // One button whatever it shows, so the symbol can change in place; the menu is empty (and never opens)
        // unless a typed message could go now instead of queueing.
        .contextMenu {
            if !voice, configuration.isWorking, configuration.canInterrupt {
                Button("Send now", systemImage: "paperplane.fill", action: onSendNow)
            }
        }
    }

    private var visibleCircleSize: CGFloat {
        min(circleSize, 48)
    }

    private var visibleChipHeight: CGFloat {
        chipHeight
    }
}
