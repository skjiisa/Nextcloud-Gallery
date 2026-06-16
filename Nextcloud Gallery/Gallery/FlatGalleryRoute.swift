//
//  FlatGalleryRoute.swift
//  Nextcloud Gallery
//
//  Navigation value for opening a folder's photos as one flattened collection.
//

import Foundation

/// Identifies a folder whose entire subtree should be shown as a single flat,
/// folder-agnostic photo collection (see ``FlatGalleryView``).
nonisolated struct FlatGalleryRoute: Hashable, Codable {
    let folderPath: String
    let title: String
    let account: String
}
