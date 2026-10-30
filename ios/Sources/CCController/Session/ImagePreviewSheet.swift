import SwiftUI
import UIKit

/// An image viewer of our own, used instead of Quick Look for images. Quick Look draws its image
/// canvas in another process, so neither the sheet nor a gesture of ours ever sees a drag on it and a
/// swipe down can't close the preview. Here the image sits in a zooming scroll view: pinch or double
/// tap to zoom, and a downward swipe while it isn't zoomed in follows the finger and closes the sheet.
struct ImagePreviewSheet: UIViewControllerRepresentable {
    let url: URL
    let image: UIImage
    let close: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let viewer = ImageViewerController(image: image, close: close)
        viewer.title = url.lastPathComponent
        let navigationController = UINavigationController(rootViewController: viewer)
        return navigationController
    }

    func updateUIViewController(_ navigationController: UINavigationController, context: Context) {
        guard let viewer = navigationController.viewControllers.first as? ImageViewerController else { return }
        viewer.title = url.lastPathComponent
        viewer.show(image)
    }
}

final class ImageViewerController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let close: @MainActor () -> Void
    private var lastLaidOutSize: CGSize = .zero

    init(image: UIImage, close: @escaping @MainActor () -> Void) {
        self.close = close
        super.init(nibName: nil, bundle: nil)
        imageView.image = image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "image-preview"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.close() }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .action,
            primaryAction: UIAction { [weak self] _ in self?.share() }
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "image-preview-share"

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityIdentifier = "image-preview-canvas"
        imageView.accessibilityLabel = title
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastLaidOutSize else { return }
        lastLaidOutSize = view.bounds.size
        fitImage()
    }

    func show(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        imageView.accessibilityLabel = title
        fitImage()
    }

    /// Sizes the image to fit the area under the navigation bar and resets the zoom.
    private func fitImage() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let available = view.bounds.inset(by: view.safeAreaInsets).size
        guard available.width > 0, available.height > 0 else { return }
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        let fittedSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = max(4, 1 / scale)
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        scrollView.contentSize = fittedSize
        centreImage()
    }

    /// Keeps the image centred in the safe area while it is smaller than the screen.
    private func centreImage() {
        let insets = view.safeAreaInsets
        let available = view.bounds.inset(by: insets).size
        let content = imageView.frame.size
        let horizontal = max(0, (available.width - content.width) / 2)
        let vertical = max(0, (available.height - content.height) / 2)
        scrollView.contentInset = UIEdgeInsets(
            top: insets.top + vertical,
            left: insets.left + horizontal,
            bottom: insets.bottom + vertical,
            right: insets.right + horizontal
        )
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centreImage()
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let zoomScale = min(scrollView.maximumZoomScale, 2.5)
        let size = CGSize(width: scrollView.bounds.width / zoomScale, height: scrollView.bounds.height / zoomScale)
        let target = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        scrollView.zoom(to: target, animated: true)
    }

    private func share() {
        guard let image = imageView.image else { return }
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(activity, animated: true)
    }

    // MARK: Swipe down to close

    private var isZoomedIn: Bool {
        scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let sheetView = navigationController?.view else { return }
        let translation = max(0, recognizer.translation(in: view).y)
        switch recognizer.state {
        case .changed:
            sheetView.transform = CGAffineTransform(translationX: 0, y: translation)
        case .ended:
            let velocity = recognizer.velocity(in: view).y
            if translation > 120 || (translation > 20 && velocity > 600) {
                close()
            } else {
                springBack(sheetView)
            }
        case .cancelled, .failed:
            springBack(sheetView)
        default:
            break
        }
    }

    private func springBack(_ sheetView: UIView) {
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            sheetView.transform = .identity
        }
    }

    /// Only a mostly downward drag while the image isn't zoomed in, so panning a zoomed image still
    /// moves around it.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard !isZoomedIn else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x) * 1.5
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer.view === scrollView
    }
}
