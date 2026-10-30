import QuickLook
import SwiftUI

/// Quick Look inside a sheet, for files other than images (those open in `ImagePreviewSheet`). The
/// navigation controller keeps Quick Look's own title and share button. Quick Look draws its content
/// in another process, so the sheet only sees a downward drag that starts on the navigation bar.
struct FilePreviewSheet: UIViewControllerRepresentable {
    let url: URL
    let close: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, close: close)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        let coordinator = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { _ in coordinator.close() }
        )
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ navigationController: UINavigationController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        (navigationController.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        let close: @MainActor () -> Void

        init(url: URL, close: @escaping @MainActor () -> Void) {
            self.url = url
            self.close = close
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
