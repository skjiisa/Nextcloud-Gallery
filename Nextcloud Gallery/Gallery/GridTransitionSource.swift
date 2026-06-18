//
//  GridTransitionSource.swift
//  Nextcloud Gallery
//
//  Shared geometry for the photo-viewer grow/shrink transition. Both grids
//  (``FolderGridViewController`` / ``FlatGalleryViewController``) back their
//  ``PhotoViewerTransitionSource`` conformance with this: locate a photo's tile by
//  `ocId`, scroll it on-screen if needed, and report its visible photo rect + image.
//

import UIKit

@MainActor
enum GridTransitionSource {
    /// The on-screen rect of the photo's tile in `space`, scrolling it into view if
    /// it isn't visible (so closing after paging lands on the right tile).
    static func sourceFrame(
        forPhotoID id: String, in space: UICoordinateSpace,
        collectionView: UICollectionView, items: [GridItemSnapshot]
    ) -> CGRect? {
        guard let indexPath = indexPath(forPhotoID: id, items: items) else { return nil }
        if !collectionView.indexPathsForVisibleItems.contains(indexPath) {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        if let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCell {
            // The photo's visible rect within the cell — correct in both fit and fill.
            return cell.photoView.convert(cell.photoView.bounds, to: space)
        }
        // Not realized even after scrolling: fall back to raw layout attributes.
        guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
        return collectionView.convert(attributes.frame, to: space)
    }

    /// The thumbnail currently shown in the photo's tile, to seed the open transition.
    static func sourceImage(
        forPhotoID id: String,
        collectionView: UICollectionView, items: [GridItemSnapshot]
    ) -> UIImage? {
        guard let indexPath = indexPath(forPhotoID: id, items: items),
              let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCell else { return nil }
        return cell.displayedImage
    }

    /// Hides/shows the photo in the tile for `id` while the hero stands in for it
    /// (no-op if the tile isn't currently realized).
    static func setHidden(
        _ hidden: Bool, forPhotoID id: String,
        collectionView: UICollectionView, items: [GridItemSnapshot]
    ) {
        guard let indexPath = indexPath(forPhotoID: id, items: items),
              let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCell else { return }
        cell.setPhotoHidden(hidden)
    }

    /// Index path of the tile for `id`. Items are a single section appended in order,
    /// so the array index is the row (folders included — lookup is by `ocId`).
    private static func indexPath(forPhotoID id: String, items: [GridItemSnapshot]) -> IndexPath? {
        guard let row = items.firstIndex(where: { $0.ocId == id }) else { return nil }
        return IndexPath(item: row, section: 0)
    }
}
