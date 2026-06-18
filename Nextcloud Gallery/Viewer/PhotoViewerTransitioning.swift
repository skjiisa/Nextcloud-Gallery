//
//  PhotoViewerTransitioning.swift
//  Nextcloud Gallery
//
//  Shared pieces for the native-Photos-style viewer transition: the grid supplies
//  the tile a photo grows out of / shrinks back into (``PhotoViewerTransitionSource``),
//  and ``PhotoHero`` builds the morphing hero image view. The grow / shrink / swipe
//  animations themselves live in ``PhotoViewerController`` (it's embedded as a child
//  of the tab's page so it rides the carousel, rather than a modal).
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
