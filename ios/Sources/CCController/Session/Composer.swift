import SwiftUI

struct ComposerConfiguration {
    let initialText: String
    let modelName: String?
    let placeholder: String
    let isWorking: Bool
    let hasTmuxPane: Bool
    let focusesOnAppear: Bool
    var isSending: Bool

    init(
        initialText: String = "",
        modelName: String? = "Fable 5.1",
        placeholder: String = "Message",
        isWorking: Bool = false,
        hasTmuxPane: Bool = false,
        focusesOnAppear: Bool = false,
        isSending: Bool = false
    ) {
        self.initialText = initialText
        self.modelName = modelName
        self.placeholder = placeholder
        self.isWorking = isWorking
        self.hasTmuxPane = hasTmuxPane
        self.focusesOnAppear = focusesOnAppear
        self.isSending = isSending
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

struct ComposerView: View {
    @Binding private var text: String
    @FocusState.Binding private var isFocused: Bool
    @Environment(\.openInspector) private var openInspector
    let configuration: ComposerConfiguration
    let onModel: () -> Void
    let onStop: () -> Void
    let onSend: () -> Void
    let onSendNow: () -> Void
    let glassNamespace: Namespace.ID?
    let resetGeneration: Int

    @State private var fieldGeneration = 0
    @ScaledMetric(relativeTo: .body) private var circleSize = CCMetrics.controlCircle
    @ScaledMetric(relativeTo: .body) private var chipHeight = CCMetrics.chipHeight

    init(
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        configuration: ComposerConfiguration,
        onModel: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onSend: @escaping () -> Void = {},
        onSendNow: @escaping () -> Void = {},
        glassNamespace: Namespace.ID? = nil,
        resetGeneration: Int = 0
    ) {
        _text = text
        _isFocused = isFocused
        self.configuration = configuration
        self.onModel = onModel
        self.onStop = onStop
        self.onSend = onSend
        self.onSendNow = onSendNow
        self.glassNamespace = glassNamespace
        self.resetGeneration = resetGeneration
    }

    var body: some View {
        bodyContent
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

    private var composerLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(configuration.placeholder, text: $text, axis: .vertical)
                .font(.body)
                .foregroundStyle(.ccLabel)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .transition(.identity)
                .id(fieldGeneration)
                .accessibilityIdentifier("composer-text")

            HStack(spacing: 8) {
                attachmentMenu
                if configuration.modelName != nil {
                    modelButton
                }
                Spacer(minLength: 0)
                if configuration.isWorking, configuration.hasTmuxPane {
                    stopButton
                }
                sendButton
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .onChange(of: resetGeneration) { _, generation in
            fieldGeneration = generation
            Task { @MainActor in
                await Task.yield()
                await Task.yield()
                isFocused = true
            }
        }
    }

    private var attachmentMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo") {}
            Button("Camera", systemImage: "camera") {}
            Button("Files", systemImage: "folder") {}
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: visibleCircleSize, height: visibleCircleSize)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .frame(width: CCMetrics.minTap, height: CCMetrics.minTap)
        .contentShape(Rectangle())
        .accessibilityLabel("Add attachment")
    }

    @ViewBuilder
    private var modelButton: some View {
        if let modelName = configuration.modelName {
            Button(action: openInspector) {
                Text(modelName)
                    .font(.footnote)
                    .foregroundStyle(.ccLabel)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .frame(height: visibleChipHeight)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .frame(minWidth: CCMetrics.minTap, minHeight: CCMetrics.minTap)
            .contentShape(Rectangle())
            .accessibilityLabel("Model \(modelName)")
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.body.weight(.semibold))
                .frame(width: visibleCircleSize, height: visibleCircleSize)
                .foregroundStyle(.ccLabel)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .frame(width: CCMetrics.minTap, height: CCMetrics.minTap)
        .contentShape(Rectangle())
        .accessibilityLabel("Stop session")
        .accessibilityIdentifier("composer-stop")
    }

    @ViewBuilder
    private var sendButton: some View {
        let button = Button(action: onSend) {
            Group {
                if configuration.isSending {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(width: visibleCircleSize, height: visibleCircleSize)
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(.ccAccent).interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .frame(width: CCMetrics.minTap, height: CCMetrics.minTap)
        .contentShape(Rectangle())
        .disabled(configuration.isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(configuration.isWorking ? "Queue message" : "Send message")
        .accessibilityIdentifier(configuration.isWorking ? "composer-queue" : "composer-send")

        if configuration.isWorking {
            button.contextMenu {
                Button("Send now", systemImage: "paperplane.fill", action: onSendNow)
            }
        } else {
            button
        }
    }

    private var visibleCircleSize: CGFloat {
        min(circleSize, 48)
    }

    private var visibleChipHeight: CGFloat {
        chipHeight
    }
}
