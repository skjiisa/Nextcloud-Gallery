//
//  BrowseTab.swift
//  Nextcloud Gallery
//
//  One browsing "instance": an independent navigation stack plus the appearance
//  and viewer state that belong to it. The app shows one tab at a time; switching
//  tabs swaps which `BrowseTab` is live (see ``TabsModel`` / ``TabbedGalleryView``).
//

import SwiftUI

/// A photo opened full-screen within a tab. Held on the tab (not as transient
/// view `@State`) so the open photo survives switching away and back — one tab
/// can sit on a single image while another shows its grid.
nonisolated struct ViewerPresentation: Identifiable, Hashable {
    /// The photos the viewer can page through, captured when the photo is opened.
    let photos: [PhotoItem]
    /// The photo shown first.
    let initialID: String

    var id: String { initialID }
}

/// A single browsing context with its own navigation history, gallery appearance,
/// and open-photo state. Reference-typed and `@Observable` so deep views can read
/// and mutate *their* tab through the environment, and so the live tab's state
/// mutates in place.
@Observable
@MainActor
final class BrowseTab: Identifiable {
    let id: UUID

    /// The navigation stack above the (always-Files-root) root screen. Bound to
    /// the tab's `NavigationStack`; persisted to restore the tab on next launch.
    var path: [BrowseRoute]

    // Per-tab flattened-gallery appearance. These used to be global `@AppStorage`;
    // moving them here lets one tab sort by date while another sorts by folder.
    var sort: GallerySortOrder
    var zoom: GalleryGridZoom
    var aspectFill: Bool

    /// The full-screen photo currently open in this tab, if any. In-memory only —
    /// a cold launch restores the browse stack but not an open viewer.
    var viewer: ViewerPresentation?

    /// Last rendered snapshot of this tab, shown as its card in the switcher.
    /// In-memory only; restored tabs fall back to a placeholder until first shown.
    var snapshot: UIImage?

    init(
        id: UUID = UUID(),
        path: [BrowseRoute] = [],
        sort: GallerySortOrder = .newestFirst,
        zoom: GalleryGridZoom = .medium,
        aspectFill: Bool = true
    ) {
        self.id = id
        self.path = path
        self.sort = sort
        self.zoom = zoom
        self.aspectFill = aspectFill
    }

    /// The tab's label in the switcher: the deepest screen's title, or "Photos"
    /// at the root.
    var title: String {
        path.last?.title ?? "Photos"
    }

    /// Opens `photo` full-screen, paging across `photos`.
    func openViewer(photos: [PhotoItem], initialID: String) {
        viewer = ViewerPresentation(photos: photos, initialID: initialID)
    }
}

// MARK: - Persistence

extension BrowseTab {
    /// A `Codable` snapshot of the restorable parts of a tab (history + appearance,
    /// not the in-memory viewer or thumbnail).
    nonisolated struct Persisted: Codable {
        var id: UUID
        var path: [BrowseRoute]
        var sort: GallerySortOrder
        var zoom: GalleryGridZoom
        var aspectFill: Bool
    }

    var persisted: Persisted {
        Persisted(id: id, path: path, sort: sort, zoom: zoom, aspectFill: aspectFill)
    }

    convenience init(persisted: Persisted) {
        self.init(
            id: persisted.id,
            path: persisted.path,
            sort: persisted.sort,
            zoom: persisted.zoom,
            aspectFill: persisted.aspectFill
        )
    }
}
