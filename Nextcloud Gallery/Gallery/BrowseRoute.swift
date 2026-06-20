//
//  BrowseRoute.swift
//  Nextcloud Gallery
//
//  One level in a tab's navigation stack above the always-present Home root.
//
//  A tab's history is a `[BrowseRoute]` layered above the Home screen (see
//  ``BrowseTab``). A level is one of three kinds — a folder (browsable grid or one
//  flattened gallery of its subtree), the account's Favorites, or a Photos album —
//  and the bottom bar's Gallery button toggles a folder level's `mode` *in place*,
//  swapping the representation without pushing or popping a screen. Favorites and
//  albums are always shown as one flat gallery.
//

import Foundation

/// One pushed level in a tab's navigation stack. `Codable` so a tab's browse stack
/// serializes and restores across launches.
nonisolated struct BrowseRoute: Hashable, Codable {
    /// Which kind of destination this level shows.
    enum Kind: Hashable, Codable {
        /// A folder from the Files tree.
        case folder
        /// The account's Nextcloud favorites (a flat gallery).
        case favorites
        /// A Nextcloud Photos album (a flat gallery), at `path` = its WebDAV collection.
        case album
    }

    let kind: Kind
    /// Folder path (`.folder`) or album WebDAV collection URL (`.album`); empty for
    /// `.favorites`.
    let path: String
    let title: String
    let account: String
    /// How a folder level is presented. Mutable: the Gallery toggle flips it in place.
    /// Meaningful only for `.folder`; favorites/albums are always `.flat`.
    var mode: Mode

    /// How a folder's contents are laid out.
    enum Mode: Hashable, Codable {
        /// A grid of the folder's immediate subfolders and photos (drill-down).
        case browse
        /// One flat, folder-agnostic gallery of every photo in the subtree.
        case flat

        mutating func toggle() { self = self == .browse ? .flat : .browse }
    }

    // MARK: - Constructors

    /// A folder level.
    static func folder(path: String, title: String, account: String, mode: Mode) -> BrowseRoute {
        BrowseRoute(kind: .folder, path: path, title: title, account: account, mode: mode)
    }

    /// The Favorites level.
    static func favorites(account: String) -> BrowseRoute {
        BrowseRoute(kind: .favorites, path: "", title: "Favorites", account: account, mode: .flat)
    }

    /// An album level.
    static func album(_ album: Album, account: String) -> BrowseRoute {
        BrowseRoute(kind: .album, path: album.davPath, title: album.name, account: account, mode: .flat)
    }
}
