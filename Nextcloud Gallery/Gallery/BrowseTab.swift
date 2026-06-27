//
//  BrowseTab.swift
//  Nextcloud Gallery
//
//  One browsing "instance": an independent navigation stack plus the appearance
//  and viewer state that belong to it. The app shows one tab at a time; switching
//  tabs swaps which `BrowseTab` is live (see ``TabsModel`` / ``TabbedGalleryView``).
//

import UIKit
import Observation

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

    /// The flattened gallery's active content filters (favorites / zoom-locked).
    /// Combinable, and remembered per tab like the other appearance state.
    var filter: GalleryFilter

    /// The full-screen photo currently open in this tab, if any. In-memory only —
    /// a cold launch restores the browse stack but not an open viewer.
    var viewer: ViewerPresentation?

    /// While a photo is open, the current image's file name — it becomes the tab's
    /// ``title`` (bar pill + switcher card) in place of the folder name. The viewer
    /// keeps it current as you page; it's cleared when the viewer closes.
    var viewerTitle: String?

    /// The grid that opened the viewer, supplying the tapped tile's geometry for the
    /// grow-open / shrink-close transition. Weak + observation-ignored: purely
    /// transient, and a fade is used if the grid is gone.
    @ObservationIgnored weak var viewerSource: (any PhotoViewerTransitionSource)?

    /// Last rendered snapshot of this tab, shown as its card in the switcher.
    /// In-memory only; restored tabs fall back to a placeholder until first shown.
    var snapshot: UIImage?

    init(
        id: UUID = UUID(),
        path: [BrowseRoute] = [],
        sort: GallerySortOrder = .newestFirst,
        zoom: GalleryGridZoom = .medium,
        aspectFill: Bool = true,
        filter: GalleryFilter = []
    ) {
        self.id = id
        self.path = path
        self.sort = sort
        self.zoom = zoom
        self.aspectFill = aspectFill
        self.filter = filter
    }

    /// The tab's label (bar pill + switcher card): the open photo's name when a photo
    /// is full-screened, otherwise the deepest screen's title, or "Home" at the root.
    var title: String {
        viewerTitle ?? path.last?.title ?? "Home"
    }

    /// Opens `photo` full-screen, paging across `photos`. `source` is the grid that
    /// opened it, used for the grow/shrink transition.
    func openViewer(photos: [PhotoItem], initialID: String, source: (any PhotoViewerTransitionSource)? = nil) {
        viewerSource = source
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
        // Optional so tabs persisted before filters existed still decode (a missing
        // key becomes nil → no active filter).
        var filter: GalleryFilter?
    }

    var persisted: Persisted {
        Persisted(id: id, path: path, sort: sort, zoom: zoom, aspectFill: aspectFill, filter: filter)
    }

    convenience init(persisted: Persisted) {
        self.init(
            id: persisted.id,
            path: persisted.path,
            sort: persisted.sort,
            zoom: persisted.zoom,
            aspectFill: persisted.aspectFill,
            filter: persisted.filter ?? []
        )
    }
}
