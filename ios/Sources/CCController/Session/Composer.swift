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

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modelName == rhs.modelName
            && lhs.placeholder == rhs.placeholder
            && lhs.isWorking == rhs.isWorking
            && lhs.canSend == rhs.canSend
            && lhs.canInterrupt == rhs.canInterrupt
            && lhs.canAttach == rhs.canAttach
            && lhs.canRunCommands == rhs.canRunCommands
            && lhs.isSending == rhs.isSending
            && lhs.hasAttachments == rhs.hasAttachments
    }

    init(
        initialText: String = "",
        draft: ComposerDraft? = nil,
        modelName: String? = "Fable 5.1",
        placeholder: String = "Message",
        isWorking: Bool = false,
        canSend: Bool = true,
        canInterrupt: Bool = false,
        canAttach: Bool = true,
        canRunCommands: Bool = true,
        focusesOnAppear: Bool = false,
        isSending: Bool = false,
        hasAttachments: Bool = false
    ) {
        self.initialText = initialText
        self.draft = draft
        self.modelName = modelName
        self.placeholder = placeholder
        self.isWorking = isWorking
        self.canSend = canSend
        self.canInterrupt = canInterrupt
        self.canAttach = canAttach
        self.canRunCommands = canRunCommands
        self.focusesOnAppear = focusesOnAppear
        self.isSending = isSending
        self.hasAttachments = hasAttachments
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
    let onAddAttachment: @MainActor @Sendable (UploadFile) -> Void
    let glassNamespace: Namespace.ID?
    let resetGeneration: Int
    let restoresFocusOnReset: Bool

    @State private var fieldGeneration = 0
    @State private var photosPresented = false
    @State private var filesPresented = false
    @State private var cameraPresented = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pickedFeedbackCount = 0
    @State private var restoreFocus = false
    private let focusLogger = Logger(subsystem: "com.example.cc-controller", category: "composer")
    @ScaledMetric(relativeTo: .body) private var circleSize = CCMetrics.controlCircle
    @ScaledMetric(relativeTo: .body) private var chipHeight = CCMetrics.chipHeight

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration
            && lhs.resetGeneration == rhs.resetGeneration
            && lhs.restoresFocusOnReset == rhs.restoresFocusOnReset
    }

    init(
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        configuration: ComposerConfiguration,
        onModel: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onSend: @escaping () -> Void = {},
        onSendNow: @escaping () -> Void = {},
        onAddAttachment: @escaping @MainActor @Sendable (UploadFile) -> Void = { _ in },
        glassNamespace: Namespace.ID? = nil,
        resetGeneration: Int = 0,
        restoresFocusOnReset: Bool = true
    ) {
        _text = text
        _isFocused = isFocused
        self.configuration = configuration
        self.onModel = onModel
        self.onStop = onStop
        self.onSend = onSend
        self.onSendNow = onSendNow
        self.onAddAttachment = onAddAttachment
        self.glassNamespace = glassNamespace
        self.resetGeneration = resetGeneration
        self.restoresFocusOnReset = restoresFocusOnReset
    }

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.composerBody)
        #endif
        bodyContent
            .photosPicker(isPresented: $photosPresented, selection: $selectedPhotos, maxSelectionCount: 10, matching: .images)
            .fileImporter(isPresented: $filesPresented, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: handleFileImport)
            .fullScreenCover(isPresented: $cameraPresented) {
                CameraPicker { image in
                    cameraPresented = false
                    guard let data = image.jpegData(compressionQuality: 0.85),
                          let file = try? AttachmentNormalizer.normalizeImage(data: data, sequence: 1) else { return }
                    add(file)
                }
                .ignoresSafeArea()
            }
            .onChange(of: selectedPhotos) { _, items in
                loadPhotos(items)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Message composer")
            .sensoryFeedback(.impact(weight: .light), trigger: pickedFeedbackCount)
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
        ComposerCard {
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

            HStack(spacing: 8) {
                if configuration.canAttach {
                    attachmentMenu
                }
                if configuration.modelName != nil, configuration.canRunCommands {
                    modelButton
                }
                Spacer(minLength: 0)
                if configuration.isWorking, configuration.canInterrupt {
                    stopButton
                }
                sendButton
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .onChange(of: resetGeneration) { _, generation in
            restoreFocus = restoresFocusOnReset && isFocused
            fieldGeneration = generation
        }
    }

    private var attachmentMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo") { photosPresented = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Camera", systemImage: "camera") { cameraPresented = true }
            }
            Button("Files", systemImage: "folder") { filesPresented = true }
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
            Button(action: onModel) {
                Text(modelName)
                    .font(.footnote)
                    .foregroundStyle(.ccLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 11)
                    .frame(height: visibleChipHeight)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .frame(minWidth: CCMetrics.minTap, minHeight: CCMetrics.minTap)
            .layoutPriority(-1)
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
        .disabled(!configuration.canSend || configuration.isSending || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !configuration.hasAttachments))
        .accessibilityLabel(configuration.isWorking ? "Queue message" : "Send message")
        .accessibilityIdentifier(configuration.isWorking ? "composer-queue" : "composer-send")

        if configuration.isWorking, configuration.canInterrupt {
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

    private func add(_ file: UploadFile) {
        onAddAttachment(file)
        pickedFeedbackCount += 1
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        selectedPhotos = []
        Task { @MainActor in
            for (index, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let file = try? AttachmentNormalizer.normalizeImage(data: data, sequence: index + 1) else { continue }
                add(file)
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mimeType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredMIMEType
            add(AttachmentNormalizer.prepareFile(data: data, name: url.lastPathComponent, mimeType: mimeType))
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, dismiss: dismiss) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onImage(image) }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}
