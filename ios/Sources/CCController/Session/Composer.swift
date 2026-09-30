import SwiftUI

struct ComposerConfiguration {
    let initialText: String
    let modelName: String
    let placeholder: String
    let isWorking: Bool
    let hasTmuxPane: Bool
    let focusesOnAppear: Bool

    init(
        initialText: String = "",
        modelName: String = "Fable 5.1",
        placeholder: String = "Message",
        isWorking: Bool = false,
        hasTmuxPane: Bool = false,
        focusesOnAppear: Bool = false
    ) {
        self.initialText = initialText
        self.modelName = modelName
        self.placeholder = placeholder
        self.isWorking = isWorking
        self.hasTmuxPane = hasTmuxPane
        self.focusesOnAppear = focusesOnAppear
    }
}

struct ComposerView: View {
    @Binding private var text: String
    @FocusState.Binding private var isFocused: Bool
    let configuration: ComposerConfiguration
    let onStop: () -> Void
    let onSend: () -> Void
    let onSendNow: () -> Void

    init(
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        configuration: ComposerConfiguration,
        onStop: @escaping () -> Void = {},
        onSend: @escaping () -> Void = {},
        onSendNow: @escaping () -> Void = {}
    ) {
        _text = text
        _isFocused = isFocused
        self.configuration = configuration
        self.onStop = onStop
        self.onSend = onSend
        self.onSendNow = onSendNow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(configuration.placeholder, text: $text, axis: .vertical)
                .font(.body)
                .foregroundStyle(.ccLabel)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityIdentifier("composer-text")

            HStack(spacing: 8) {
                attachmentMenu
                modelButton
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message composer")
    }

    private var attachmentMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo") {}
            Button("Camera", systemImage: "camera") {}
            Button("Files", systemImage: "folder") {}
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Add attachment")
    }

    private var modelButton: some View {
        Button {} label: {
            Text(configuration.modelName)
                .font(.footnote)
                .foregroundStyle(.ccLabel)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(minHeight: 32)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model \(configuration.modelName)")
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.footnote.weight(.bold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(.ccAccent)
        .accessibilityLabel("Stop session")
    }

    @ViewBuilder
    private var sendButton: some View {
        let button = Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.body.weight(.bold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .tint(.ccAccent)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(configuration.isWorking ? "Queue message" : "Send message")

        if configuration.isWorking {
            button.contextMenu {
                Button("Send now", systemImage: "paperplane.fill", action: onSendNow)
            }
        } else {
            button
        }
    }
}
