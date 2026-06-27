//
//  GalleryFilter.swift
//  Nextcloud Gallery
//
//  Which photos a flattened gallery shows. Combinable (an item must satisfy every
//  enabled filter), selectable from the gallery's nav bar, and persisted per
//  ``BrowseTab``. ``favorites`` is matched against the account's live Nextcloud
//  favorites; ``zoomLocked`` against the local ``ZoomLockStore``.
//
//  Add a case here plus an entry in ``options`` to introduce a new filter — the
//  menu is built from `options`.
//

import Foundation

nonisolated struct GalleryFilter: OptionSet, Codable, Sendable {
    let rawValue: Int

    /// Only photos favorited on the server.
    static let favorites = GalleryFilter(rawValue: 1 << 0)
    /// Only photos with a saved zoom lock.
    static let zoomLocked = GalleryFilter(rawValue: 1 << 1)

    /// The toggles shown in the filter menu, in display order.
    static let options: [(filter: GalleryFilter, label: String, symbol: String)] = [
        (.favorites, "Favorites", "heart"),
        (.zoomLocked, "Zoom Locked", "lock"),
    ]
}
