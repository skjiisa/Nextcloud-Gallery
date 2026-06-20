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
    /// Drill into a folder. Folders with no subfolders open straight into the
    /// flattened gallery (better for images, and browsing is redundant there).
    func openFolder(_ route: FolderRoute)
    /// Open a folder in a new background tab and switch to it ("Open in New Tab").
    func openFolderInNewTab(_ route: FolderRoute)
    /// Open the account's Nextcloud favorites as a flat gallery.
    func openFavorites()
    /// Open a Nextcloud Photos album as a flat gallery.
    func openAlbum(_ album: Album)
    /// Present the full-screen viewer for `photos`, starting at `initialID`. `source`
    /// supplies the tapped tile's geometry for the grow-open / shrink-close
    /// transition (held weakly; a fade is used if it's gone).
    func openViewer(photos: [PhotoItem], initialID: String, source: (any PhotoViewerTransitionSource)?)
}
