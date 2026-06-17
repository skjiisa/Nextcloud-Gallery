//
//  GalleryNavigator.swift
//  Nextcloud Gallery
//
//  How a grid asks its host (the tab's navigation controller) to navigate. Keeps
//  the grids decoupled from tab/carousel machinery: they describe intent with
//  route values, and the host pushes the destination, keeps ``BrowseTab/path`` in
//  sync, opens new tabs, or presents the viewer.
//

import Foundation

@MainActor
protocol GalleryNavigator: AnyObject {
    /// Drill into a folder (push onto this tab's stack).
    func openFolder(_ route: FolderRoute)
    /// Open a folder's subtree as a flattened gallery (push).
    func openFlatGallery(_ route: FlatGalleryRoute)
    /// Open a folder in a new background tab and switch to it ("Open in New Tab").
    func openFolderInNewTab(_ route: FolderRoute)
    /// Present the full-screen viewer for `photos`, starting at `initialID`.
    func openViewer(photos: [PhotoItem], initialID: String)
}
