//
//  BrowseRoute.swift
//  Nextcloud Gallery
//
//  A single, typed navigation value covering every screen a tab can push.
//
//  A tab's history is a `[BrowseRoute]` bound to its `NavigationStack` (see
//  ``BrowseTab``). Folding the two route types into one enum keeps the path
//  homogeneous (so it binds to the stack and serializes for restore) while still
//  distinguishing a folder drill-down from a flattened gallery.
//

import Foundation

/// One entry in a tab's navigation stack: either a folder drill-down or a
/// flattened gallery of a folder's subtree.
nonisolated enum BrowseRoute: Hashable, Codable {
    case folder(FolderRoute)
    case flat(FlatGalleryRoute)

    /// The screen title for this destination — used to label the tab in the
    /// switcher (the deepest screen names the tab).
    var title: String {
        switch self {
        case .folder(let route): route.title
        case .flat(let route): route.title
        }
    }
}
