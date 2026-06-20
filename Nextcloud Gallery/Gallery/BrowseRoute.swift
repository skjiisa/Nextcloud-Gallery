//
//  BrowseRoute.swift
//  Nextcloud Gallery
//
//  One level in a tab's navigation stack: a folder, plus how it's being shown.
//
//  A tab's history is a `[BrowseRoute]` above the always-present Files-root level
//  (see ``BrowseTab``). Each level is a single folder that can be presented two ways
//  — a browsable grid of its immediate contents, or one flattened gallery of its
//  whole subtree — and the bottom bar's Gallery button toggles `mode` *in place*,
//  swapping the representation without pushing or popping a screen.
//

import Foundation

/// One folder level in a tab's navigation stack, shown in a given presentation
/// ``Mode``. `Codable` so a tab's browse stack serializes and restores across
/// launches.
nonisolated struct BrowseRoute: Hashable, Codable {
    let folderPath: String
    let title: String
    let account: String
    /// How this level is presented. Mutable: the Gallery toggle flips it in place.
    var mode: Mode

    /// How a folder's contents are laid out.
    enum Mode: Hashable, Codable {
        /// A grid of the folder's immediate subfolders and photos (drill-down).
        case browse
        /// One flat, folder-agnostic gallery of every photo in the subtree.
        case flat

        mutating func toggle() { self = self == .browse ? .flat : .browse }
    }
}
