//
//  CoverTile.swift
//  Nextcloud Gallery
//
//  One photo tile used in a folder's 2x2 cover.
//

import Foundation

/// A single photo chosen to represent a folder, carrying everything the cell
/// needs to fetch its thumbnail without an extra lookup. Stored (Codable) inside
/// ``FolderState`` and rendered directly by the folder cell.
nonisolated struct CoverTile: Codable, Hashable, Sendable {
    let ocId: String
    let fileId: String
    let etag: String
}
