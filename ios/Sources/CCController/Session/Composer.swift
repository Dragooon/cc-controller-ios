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
        hasAttachments: Bool = false
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
    private let focusLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc-controller", category: "composer")
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
            .photosPicker(isPresented: $photosPresented, selection: $selectedPhotos, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
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

    /// Empty and not in use: one row, like the system and Claude apps, so the transcript gets the space back. Tapping
    /// in, a draft or an attachment brings back the full composer with the model chip.
    private var isCompact: Bool {
        !isFocused && text.isEmpty && !configuration.hasAttachments
    }

    private var composerLayout: some View {
        ComposerCard {
            // The field keeps one place in the tree in both layouts, so focusing it (which switches the layout) never
            // rebuilds it and drops the keyboard.
            HStack(alignment: .center, spacing: 8) {
                if isCompact, configuration.canAttach {
                    attachmentMenu
                }
                messageField
                if isCompact {
                    if configuration.isWorking, configuration.canInterrupt {
                        stopButton
                    }
                    sendButton
                }
            }
            if !isCompact {
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
        }
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

    // Camera availability is fixed for the device, and the lookup goes through MobileGestalt,
    // so read it once instead of on every composer body evaluation.
    @MainActor private static let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

    private var attachmentMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo") { photosPresented = true }
            if Self.cameraAvailable {
                Button("Camera", systemImage: "camera") { cameraPresented = true }
            }
            Button("Files", systemImage: "folder") { filesPresented = true }
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
            .tapOutset(horizontal: 4, vertical: 4)
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
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { continue }
                    defer { try? FileManager.default.removeItem(at: movie.url) }
                    guard let data = await Self.compressedMovie(at: movie.url) else { continue }
                    add(AttachmentNormalizer.prepareFile(data: data, name: "video-\(index + 1).mp4", mimeType: "video/mp4"))
                    continue
                }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let file = try? AttachmentNormalizer.normalizeImage(data: data, sequence: index + 1) else { continue }
                add(file)
            }
        }
    }

    /// A picked video re-encoded at 720p so it fits the upload limit, falling back to medium quality if it's still too
    /// big. Nil if it can't be read or exported.
    nonisolated private static func compressedMovie(at url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        for preset in [AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality] {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                try await session.export(to: output, as: .mp4)
            } catch {
                continue
            }
            guard let data = try? Data(contentsOf: output) else { continue }
            if data.count <= AttachmentNormalizer.maxFileBytes || preset == AVAssetExportPresetMediumQuality {
                return data
            }
        }
        return nil
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

/// A video from the photo library, copied somewhere the app can read it after the picker lets go.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
