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
    /// Set when the view must (re-)settle to its rest framing on the next layout — e.g.
    /// after locking, or a size change. Cleared once seated against real bounds.
    private var needsSeat = false
    /// Last `isZoomedIn` value reported through `onZoomChanged`, so the callback fires
    /// only on transitions rather than every frame of a pinch.
    private var lastZoomedReported: Bool?

    /// When set, the photo is *locked*: this scale + pan becomes the new rest state —
    /// the minimum zoom (you can't pull out past it), the home a double-tap returns to,
    /// and the framing from which a downward swipe dismisses (because `isZoomedIn` is
    /// measured against it, so it reads as "not zoomed").
    private(set) var lockedBaseline: ZoomLock?
    /// Headroom for zooming *in* past a locked baseline.
    private static let lockedZoomHeadroom: CGFloat = 3
    private static let defaultMaxZoom: CGFloat = 5

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
        maximumZoomScale = Self.defaultMaxZoom
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

    /// The current zoom + pan as a lockable snapshot, or nil at the rest scale (nothing
    /// worth locking).
    var currentLock: ZoomLock? {
        isZoomedIn ? ZoomLock(scale: zoomScale, offset: contentOffset) : nil
    }

    /// Adopt `baseline` as the new rest state: it becomes the minimum zoom and the home
    /// the photo settles to, with headroom to zoom further in. Seats it now if laid out,
    /// else on the next layout (e.g. while reopening a locked photo).
    func lock(to baseline: ZoomLock) {
        lockedBaseline = baseline
        requestSeat()
    }

    /// Drop the locked baseline back to fit-to-screen. The current zoom is kept (now
    /// reading as "zoomed in"), clamped back under the default ceiling.
    func unlock() {
        lockedBaseline = nil
        minimumZoomScale = 1
        maximumZoomScale = Self.defaultMaxZoom
        if zoomScale > maximumZoomScale { setZoomScale(maximumZoomScale, animated: true) }
        updateScrollEnabled()
        reportZoomState()
    }

    /// Asks for a re-seat to the rest framing — synchronously if already laid out (a live
    /// lock toggle), otherwise on the next layout pass.
    private func requestSeat() {
        needsSeat = true
        setNeedsLayout()
        if bounds.width > 0, bounds.height > 0 { layoutIfNeeded() }
    }

    /// Re-fits the image view to the current viewport and settles to the rest framing:
    /// the locked baseline's scale + pan, or plain fit-to-screen. Always passes through
    /// scale 1 first, so the zoom takes even when `zoomScale` already equals the target
    /// (a bare `setZoomScale` to the same value is a no-op and would leave the just-reset
    /// image view un-zoomed).
    private func seatToBaseline() {
        minimumZoomScale = 1
        setZoomScale(1, animated: false)
        imageView.frame = bounds
        if let baseline = lockedBaseline {
            maximumZoomScale = max(Self.defaultMaxZoom, baseline.scale * Self.lockedZoomHeadroom)
            minimumZoomScale = baseline.scale
            setZoomScale(baseline.scale, animated: false)
            contentOffset = clamped(baseline.offset)
        } else {
            maximumZoomScale = Self.defaultMaxZoom
        }
        updateScrollEnabled()
        reportZoomState()
    }

    /// At the rest scale the photo doesn't pan — the viewer's swipe-dismiss / paging
    /// own a drag there (matching fit-scale). Panning is only for a zoomed-in photo.
    private func updateScrollEnabled() {
        panGestureRecognizer.isEnabled = isZoomedIn
    }

    private func reportZoomState() {
        let zoomed = isZoomedIn
        guard zoomed != lastZoomedReported else { return }
        lastZoomedReported = zoomed
        onZoomChanged?(zoomed)
    }

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
        // A size change forces a re-seat (zoom is content-size-relative, so it must be
        // recomputed for the new viewport); zoom changes alone don't change bounds.
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            needsSeat = true
        }
        if needsSeat, bounds.width > 0, bounds.height > 0 {
            needsSeat = false
            seatToBaseline()
        }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // No image-panning at the rest scale; report only on zoomed/not-zoomed flips.
        updateScrollEnabled()
        reportZoomState()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // A locked photo must not pan at its rest scale. Pinning the offset here kills
        // any drift that leaks in from a partial swipe-down (its leftover momentum or
        // bounce) — disabling the pan recognizer alone isn't reliable, as UIScrollView
        // re-enables it. Skipped while actively zooming, where the offset legitimately
        // moves, and when already parked.
        guard let baseline = lockedBaseline, !isZoomedIn, !isZooming, !isZoomBouncing else { return }
        let target = clamped(baseline.offset)
        if contentOffset != target { contentOffset = target }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // Pinching back out bottoms out at the locked baseline — snap to its exact pan
        // so it returns to *that* position, not wherever the pinch happened to land.
        guard let baseline = lockedBaseline, scale <= baseline.scale + 0.001 else { return }
        setContentOffset(clamped(baseline.offset), animated: true)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if isZoomedIn {
            // Zoom back to the rest state. When locked, return to the baseline's exact
            // framing (scale + pan); otherwise fit to screen.
            if let baseline = lockedBaseline {
                zoom(to: baselineRect(baseline), animated: true)
            } else {
                setZoomScale(minimumZoomScale, animated: true)
            }
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

    /// The rect in `imageView`'s coordinates whose zoom-to lands exactly on a baseline
    /// (scale + pan) — used to return there on double-tap.
    private func baselineRect(_ baseline: ZoomLock) -> CGRect {
        let s = baseline.scale
        return CGRect(x: baseline.offset.x / s, y: baseline.offset.y / s,
                      width: bounds.width / s, height: bounds.height / s)
    }

    private func clamped(_ offset: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, offset.x), max(0, contentSize.width - bounds.width)),
                y: min(max(0, offset.y), max(0, contentSize.height - bounds.height)))
    }
}
