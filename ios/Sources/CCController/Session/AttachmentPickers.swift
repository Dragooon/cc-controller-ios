import AVFoundation
import CCKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Where an attachment comes from. The composer's + menu and voice mode's Attach button both offer these.
enum AttachmentSource: Hashable {
    case photos
    case camera
    case files
}

/// The menu items for picking an attachment source.
struct AttachmentSourceButtons: View {
    let choose: (AttachmentSource) -> Void

    // Camera availability is fixed for the device, and the lookup goes through MobileGestalt, so read it once.
    @MainActor private static let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

    var body: some View {
        Button("Photos", systemImage: "photo") { choose(.photos) }
        if Self.cameraAvailable {
            Button("Camera", systemImage: "camera") { choose(.camera) }
        }
        Button("Files", systemImage: "folder") { choose(.files) }
    }
}

/// The photo, camera and file pickers behind an attachment menu. Setting `request` opens one; every file picked is
/// normalised (images resized, videos re-encoded) and handed to `onAdd`.
struct AttachmentPickers: ViewModifier {
    @Binding var request: AttachmentSource?
    let onAdd: @MainActor @Sendable (UploadFile) -> Void
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pickedFeedbackCount = 0

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: presented(.photos), selection: $selectedPhotos, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
            .fileImporter(isPresented: presented(.files), allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: handleFileImport)
            .fullScreenCover(isPresented: presented(.camera)) {
                CameraPicker { image in
                    request = nil
                    guard let data = image.jpegData(compressionQuality: 0.85),
                          let file = try? AttachmentNormalizer.normalizeImage(data: data, sequence: 1) else { return }
                    add(file)
                }
                .ignoresSafeArea()
            }
            .onChange(of: selectedPhotos) { _, items in
                loadPhotos(items)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: pickedFeedbackCount)
    }

    private func presented(_ source: AttachmentSource) -> Binding<Bool> {
        Binding(
            get: { request == source },
            set: { isPresented in
                if isPresented { request = source } else if request == source { request = nil }
            }
        )
    }

    private func add(_ file: UploadFile) {
        onAdd(file)
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
