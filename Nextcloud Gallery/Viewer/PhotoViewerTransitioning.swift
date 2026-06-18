//
//  PhotoViewerTransitioning.swift
//  Nextcloud Gallery
//
//  The native-Photos-style transition for the full-screen viewer: the tapped tile
//  grows into the photo on open, contracts back into its tile on close, and follows
//  the finger during a swipe-down dismissal. All three share one hero `UIImageView`
//  that morphs between the tile's (cropped, rounded) frame and the photo's
//  full-screen aspect-fit frame.
//
//  Geometry comes from the grid via ``PhotoViewerTransitionSource`` — the grid is the
//  only thing that knows where a tile sits — and on close the *current* photo's tile
//  is re-queried (the grid scrolls it on-screen), so paging then dismissing lands on
//  the right tile, like Photos.
//

import UIKit

// MARK: - Source

/// Supplies the on-screen tile a photo should grow out of / shrink back into.
/// Implemented by the grids (``FolderGridViewController`` / ``FlatGalleryViewController``).
@MainActor
protocol PhotoViewerTransitionSource: AnyObject {
    /// Frame of the tile for `id`, in `space`'s coordinates, scrolling it on-screen
    /// if needed. Nil when there's no such tile (the transition falls back to a fade).
    func viewerSourceFrame(forPhotoID id: String, in space: UICoordinateSpace) -> CGRect?
    /// The thumbnail currently shown in that tile, to seed the hero image on open.
    func viewerSourceImage(forPhotoID id: String) -> UIImage?
    /// Hides/shows the tile's photo while the hero stands in for it, so the grid
    /// doesn't show a second copy of the image mid-animation.
    func setViewerSourceHidden(_ hidden: Bool, forPhotoID id: String)
}

// MARK: - Controller (transitioning delegate)

/// Vends the open/close animators and the interactive swipe-down driver, and carries
/// the shared `source` reference. Set as the viewer's `transitioningDelegate`.
@MainActor
final class PhotoViewerTransitionController: NSObject, UIViewControllerTransitioningDelegate {
    weak var source: (any PhotoViewerTransitionSource)?

    /// Set true by the viewer's pan gesture just before `dismiss` so the dismissal
    /// is driven interactively; false for a tapped-Done dismissal.
    var isInteractive = false

    /// The live driver while a swipe-down is in flight (so the viewer can forward
    /// pan updates to it). Cleared when the transition finishes or cancels.
    private(set) var activeDriver: PhotoViewerInteractiveDismiss?

    func animationController(
        forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        PhotoViewerHeroAnimator(mode: .present, source: self.source)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        PhotoViewerHeroAnimator(mode: .dismiss, source: source)
    }

    func interactionControllerForDismissal(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        guard isInteractive else { return nil }
        let driver = PhotoViewerInteractiveDismiss(source: source)
        driver.onComplete = { [weak self] in self?.activeDriver = nil }
        activeDriver = driver
        return driver
    }
}

// MARK: - Shared geometry

enum PhotoHero {
    /// Corner radius the hero rounds to at the tile end (matches the grid tiles).
    static let tileCornerRadius = LayoutMetrics.tileCornerRadius

    /// A fresh hero image view configured to crop like a tile. At the full-screen end
    /// the frame already has the image's aspect ratio, so aspect-fill shows the whole
    /// photo there and only crops as it morphs toward the square tile.
    static func makeHeroView(image: UIImage?) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerCurve = .continuous
        return view
    }
}

// MARK: - Open / close animator

/// Drives the non-interactive grow-open and shrink-close animations.
@MainActor
final class PhotoViewerHeroAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    enum Mode { case present, dismiss }

    private let mode: Mode
    private weak var source: (any PhotoViewerTransitionSource)?

    init(mode: Mode, source: (any PhotoViewerTransitionSource)?) {
        self.mode = mode
        self.source = source
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        mode == .present ? 0.42 : 0.32
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        switch mode {
        case .present: animatePresent(context)
        case .dismiss: animateDismiss(context)
        }
    }

    private func animatePresent(_ context: UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let viewer = context.viewController(forKey: .to) as? PhotoViewerController else {
            context.completeTransition(false); return
        }
        let viewerView = viewer.view!
        viewerView.frame = context.finalFrame(for: viewer)
        container.addSubview(viewerView)
        viewerView.layoutIfNeeded()

        let id = viewer.currentPhotoID
        let heroImage = source?.viewerSourceImage(forPhotoID: id) ?? viewer.currentDisplayedImage
        let sourceFrame = source?.viewerSourceFrame(forPhotoID: id, in: viewerView)
        let aspect = heroImage.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 } ?? viewer.currentAspectRatio
        let endFrame = viewer.fittedRect(forAspectRatio: aspect)
        let duration = transitionDuration(using: context)

        viewer.backdropView.alpha = 0
        viewer.setChromeAlpha(0)

        guard let sourceFrame, let heroImage else {
            // No tile to grow from: cross-dissolve the whole viewer in.
            viewer.backdropView.alpha = 1
            viewerView.alpha = 0
            UIView.animate(withDuration: duration, animations: {
                viewerView.alpha = 1
                viewer.setChromeAlpha(1)
            }, completion: { _ in context.completeTransition(!context.transitionWasCancelled) })
            return
        }

        viewer.setPageContentHidden(true)
        source?.setViewerSourceHidden(true, forPhotoID: id)
        let hero = PhotoHero.makeHeroView(image: heroImage)
        hero.frame = sourceFrame
        hero.layer.cornerRadius = PhotoHero.tileCornerRadius
        viewer.insertTransitionHero(hero)

        // Sharpen the hero in place as the page's loader yields preview/full stages,
        // so a tall portrait doesn't stay soft for the whole grow.
        viewer.onCurrentImageUpgrade = { [weak hero] image in hero?.image = image }

        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.curveEaseOut]) {
            hero.frame = endFrame
            hero.layer.cornerRadius = 0
            viewer.backdropView.alpha = 1
            viewer.setChromeAlpha(1)
        } completion: { _ in
            viewer.onCurrentImageUpgrade = nil
            hero.removeFromSuperview()
            viewer.setPageContentHidden(false)
            self.source?.setViewerSourceHidden(false, forPhotoID: id)
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    private func animateDismiss(_ context: UIViewControllerContextTransitioning) {
        guard let viewer = context.viewController(forKey: .from) as? PhotoViewerController else {
            context.completeTransition(false); return
        }
        let id = viewer.currentPhotoID
        let heroImage = viewer.currentDisplayedImage ?? source?.viewerSourceImage(forPhotoID: id)
        let startFrame = viewer.currentImageOnScreenRect ?? viewer.fittedRect(forAspectRatio: viewer.currentAspectRatio)
        let destFrame = source?.viewerSourceFrame(forPhotoID: id, in: viewer.view)
        let duration = transitionDuration(using: context)

        guard let heroImage else {
            UIView.animate(withDuration: duration, animations: {
                viewer.view.alpha = 0
            }, completion: { _ in context.completeTransition(!context.transitionWasCancelled) })
            return
        }

        viewer.setPageContentHidden(true)
        source?.setViewerSourceHidden(true, forPhotoID: id)
        let hero = PhotoHero.makeHeroView(image: heroImage)
        hero.frame = startFrame
        viewer.insertTransitionHero(hero)

        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            if let destFrame {
                hero.frame = destFrame
                hero.layer.cornerRadius = PhotoHero.tileCornerRadius
            } else {
                hero.alpha = 0
                hero.frame = startFrame.insetBy(dx: startFrame.width * 0.2, dy: startFrame.height * 0.2)
                    .offsetBy(dx: 0, dy: startFrame.height * 0.3)
            }
            viewer.backdropView.alpha = 0
            viewer.setChromeAlpha(0)
        } completion: { _ in
            hero.removeFromSuperview()
            self.source?.setViewerSourceHidden(false, forPhotoID: id)
            context.completeTransition(!context.transitionWasCancelled)
        }
    }
}

// MARK: - Interactive swipe-down driver

/// Drives the swipe-down dismissal: the hero follows the finger and shrinks while the
/// backdrop fades to reveal the grid; release past threshold lands it in the tile,
/// a short release springs it back. Pan updates are forwarded from the viewer.
@MainActor
final class PhotoViewerInteractiveDismiss: NSObject, UIViewControllerInteractiveTransitioning {
    /// Called once the transition finishes *or* cancels, so the controller can drop
    /// its reference to this driver.
    var onComplete: (() -> Void)?

    private weak var source: (any PhotoViewerTransitionSource)?
    private var context: UIViewControllerContextTransitioning?
    private weak var viewer: PhotoViewerController?
    private let hero = UIImageView()
    private var startFrame: CGRect = .zero
    private var didStart = false
    /// The photo being dismissed, captured once at gesture start. Used for both the
    /// hide and the matching unhide so they can't target different tiles if the
    /// current photo shifts mid-gesture.
    private var photoID = ""

    /// A finish/cancel that arrived before `startInteractiveTransition` set us up
    /// (possible when a very fast flick's gesture events land in one batch). Applied
    /// as soon as the transition actually starts, so the dismissal never gets stuck.
    private enum PendingEnd { case finish(CGPoint), cancel }
    private var pendingEnd: PendingEnd?

    init(source: (any PhotoViewerTransitionSource)?) {
        self.source = source
    }

    func startInteractiveTransition(_ transitionContext: UIViewControllerContextTransitioning) {
        context = transitionContext
        guard let viewer = transitionContext.viewController(forKey: .from) as? PhotoViewerController else {
            transitionContext.completeTransition(false); onComplete?(); return
        }
        self.viewer = viewer
        photoID = viewer.currentPhotoID

        startFrame = viewer.currentImageOnScreenRect ?? viewer.fittedRect(forAspectRatio: viewer.currentAspectRatio)
        let image = viewer.currentDisplayedImage ?? source?.viewerSourceImage(forPhotoID: photoID)

        hero.image = image
        hero.contentMode = .scaleAspectFill
        hero.clipsToBounds = true
        hero.layer.cornerCurve = .continuous
        hero.frame = startFrame
        viewer.insertTransitionHero(hero)

        viewer.setPageContentHidden(true)
        source?.setViewerSourceHidden(true, forPhotoID: photoID)
        didStart = true

        // If the gesture already ended before we got here, apply it now.
        if let pending = pendingEnd {
            pendingEnd = nil
            switch pending {
            case .finish(let velocity): finish(velocity: velocity)
            case .cancel: cancel()
            }
        }
    }

    /// `progress` in 0...1 (drag distance toward the dismiss point); `translation` in
    /// the viewer's coordinates.
    func update(progress: CGFloat, translation: CGPoint) {
        guard didStart else { return }
        let scale = max(0.5, 1 - progress * 0.5)
        let size = CGSize(width: startFrame.width * scale, height: startFrame.height * scale)
        let center = CGPoint(x: startFrame.midX + translation.x, y: startFrame.midY + translation.y)
        hero.frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        viewer?.backdropView.alpha = max(0, 1 - progress)
        context?.updateInteractiveTransition(progress)
    }

    /// Commit: land the hero in the current photo's tile (or fade it away) and tear
    /// the viewer down. `velocity` is the gesture's release velocity (points/sec),
    /// carried into the spring so the throw continues naturally.
    func finish(velocity: CGPoint = .zero) {
        guard didStart else { pendingEnd = .finish(velocity); return }
        guard let context, let viewer else { onComplete?(); return }
        let destFrame = source?.viewerSourceFrame(forPhotoID: photoID, in: viewer.view)
        // Re-hide in case computing the frame just scrolled the tile on-screen.
        source?.setViewerSourceHidden(true, forPhotoID: photoID)

        // Convert the finger's points/sec into the spring's distance-fraction/sec,
        // capped low so a hard flick continues the throw without shooting way past
        // the cell and snapping back. A slow drag is already well under the cap, so
        // its (well-liked) settle is unchanged.
        let distance = destFrame.map { abs($0.midY - hero.frame.midY) } ?? 1
        let springVelocity = min(1.5, abs(velocity.y) / max(1, distance))

        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: springVelocity, options: [.curveEaseOut, .allowUserInteraction]) {
            if let destFrame {
                self.hero.frame = destFrame
                self.hero.layer.cornerRadius = PhotoHero.tileCornerRadius
            } else {
                self.hero.alpha = 0
                self.hero.frame = self.hero.frame
                    .insetBy(dx: self.hero.frame.width * 0.15, dy: self.hero.frame.height * 0.15)
                    .offsetBy(dx: 0, dy: 80)
            }
            viewer.backdropView.alpha = 0
        } completion: { _ in
            self.hero.removeFromSuperview()
            self.source?.setViewerSourceHidden(false, forPhotoID: self.photoID)
            context.finishInteractiveTransition()
            context.completeTransition(true)
            viewer.handleDidDismiss()
            self.onComplete?()
        }
    }

    /// Abort: spring the hero back to full-screen, restore the backdrop, and keep the
    /// viewer presented.
    func cancel() {
        guard didStart else { pendingEnd = .cancel; return }
        guard let context, let viewer else { onComplete?(); return }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3, options: [.curveEaseOut]) {
            self.hero.frame = self.startFrame
            self.hero.layer.cornerRadius = 0
            viewer.backdropView.alpha = 1
        } completion: { _ in
            self.hero.removeFromSuperview()
            viewer.setPageContentHidden(false)
            viewer.setChromeHidden(false)
            self.source?.setViewerSourceHidden(false, forPhotoID: self.photoID)
            context.cancelInteractiveTransition()
            context.completeTransition(false)
            self.onComplete?()
        }
    }
}
