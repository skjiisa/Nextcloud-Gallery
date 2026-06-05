//
//  ZoomableImageView.swift
//  Nextcloud Gallery
//
//  Pinch / double-tap zoom for one photo.
//
//  This is a deliberate UIKit bridge: UIScrollView gives correct, system-feeling
//  pinch-zoom, double-tap-to-point zoom, panning, and rubber-banding for free,
//  which is fiddly and imperfect to reproduce in pure SwiftUI. Everything else in
//  the viewer is SwiftUI.
//

import SwiftUI
import UIKit

/// A zoomable image surface backed by `UIScrollView`. Reports whether it's zoomed
/// (via `isZoomed`) so the surrounding pager can disable horizontal paging.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    @Binding var isZoomed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    func makeUIView(context: Context) -> BoundsAwareScrollView {
        let scrollView = BoundsAwareScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // Keep the image view filling the viewport; reset zoom on size changes.
        scrollView.onBoundsChange = { [weak scrollView] bounds in
            guard let scrollView else { return }
            imageView.frame = bounds
            scrollView.setZoomScale(1, animated: false)
        }

        return scrollView
    }

    func updateUIView(_ scrollView: BoundsAwareScrollView, context: Context) {
        // Swap the image without disturbing the current zoom (aspect-fit re-fits).
        if context.coordinator.imageView.image !== image {
            context.coordinator.imageView.image = image
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        @Binding var isZoomed: Bool

        init(isZoomed: Binding<Bool>) {
            _isZoomed = isZoomed
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.001
            if zoomed != isZoomed {
                isZoomed = zoomed
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let targetScale = min(scrollView.maximumZoomScale, scrollView.minimumZoomScale * 3)
                let point = gesture.location(in: imageView)
                let size = scrollView.bounds.size
                let width = size.width / targetScale
                let height = size.height / targetScale
                let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

/// A `UIScrollView` that reports viewport size changes so the image view can be
/// re-laid-out (without firing during zoom, which changes content size, not bounds).
final class BoundsAwareScrollView: UIScrollView {
    var onBoundsChange: ((CGRect) -> Void)?
    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            onBoundsChange?(bounds)
        }
    }
}
