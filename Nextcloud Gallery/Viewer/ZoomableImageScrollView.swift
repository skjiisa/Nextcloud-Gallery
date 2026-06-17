//
//  ZoomableImageScrollView.swift
//  Nextcloud Gallery
//
//  Pinch / double-tap zoom for one photo, backed by UIScrollView — which gives
//  correct, system-feeling pinch-zoom, double-tap-to-point zoom, panning, and
//  rubber-banding for free. (Salvaged from the old SwiftUI `ZoomableImageView`
//  bridge, now used directly without the `UIViewRepresentable` shell.)
//

import UIKit

final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()

    /// Reports whether the view is zoomed in, so the pager can disable paging.
    var onZoomChanged: ((Bool) -> Void)?

    /// The double-tap-to-zoom recognizer, exposed so the viewer's single-tap
    /// (toggle chrome) can require it to fail.
    let doubleTap = UITapGestureRecognizer()

    private var lastBoundsSize: CGSize = .zero

    var image: UIImage? {
        get { imageView.image }
        set {
            // Swap without disturbing the current zoom (aspect-fit re-fits).
            if imageView.image !== newValue { imageView.image = newValue }
        }
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Whether the photo is zoomed past its fitted size. The viewer reads this to
    /// gate swipe-to-dismiss (a downward pan pans the zoomed photo instead).
    var isZoomedIn: Bool { zoomScale > minimumZoomScale + 0.001 }

    /// The on-screen rect of the displayed image pixels — the aspect-fit rect within
    /// the image view, honoring the current zoom and pan — in `view`'s coordinate
    /// space. Nil if no image yet. The hero transition uses this to line the photo
    /// up exactly with where it sits on screen.
    func displayedImageRect(in view: UIView) -> CGRect? {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return nil }
        let boundsSize = imageView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return nil }
        let scale = min(boundsSize.width / image.size.width, boundsSize.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rectInImageView = CGRect(
            x: (boundsSize.width - fitted.width) / 2,
            y: (boundsSize.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height
        )
        return imageView.convert(rectInImageView, to: view)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the image view filling the viewport; reset zoom on size changes only
        // (not on zoom, which changes content size, not bounds).
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            imageView.frame = bounds
            setZoomScale(1, animated: false)
        }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let zoomed = zoomScale > minimumZoomScale + 0.001
        onZoomChanged?(zoomed)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let targetScale = min(maximumZoomScale, minimumZoomScale * 3)
            let point = gesture.location(in: imageView)
            let size = bounds.size
            let width = size.width / targetScale
            let height = size.height / targetScale
            let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
            zoom(to: rect, animated: true)
        }
    }
}
