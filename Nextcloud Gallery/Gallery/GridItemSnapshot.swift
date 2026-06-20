//
//  GridItemSnapshot.swift
//  Nextcloud Gallery
//
//  A Sendable value snapshot of one grid entry (folder or photo).
//
//  The UIKit grids never hold live `@Model` objects: ``CacheStore`` fetches off the
//  main thread and maps each ``CachedItem`` into one of these, so diffable data
//  sources diff plain values and cells read stable data with no per-cell SwiftData
//  access (the per-cell `@Query` fan-out was the SwiftUI grids' main hang source).
//

import Foundation

/// Everything a grid cell needs to render and a tap needs to navigate, captured
/// as immutable value data decoupled from the cache.
nonisolated struct GridItemSnapshot: Hashable, Sendable, Identifiable {
    let ocId: String
    let account: String
    let isDirectory: Bool
    let fileName: String
    let fileId: String
    let etag: String
    let hasPreview: Bool
    let width: Int
    let height: Int
    /// Normalized full path of this item (folder destination / photo download path).
    let fullPath: String
    /// Up to 4 representative tiles for a folder's 2x2 cover; empty for photos.
    let coverTiles: [CoverTile]

    var id: String { ocId }

    /// The photo's aspect ratio from its stored dimensions (square fallback).
    var aspectRatio: CGFloat {
        width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : 1
    }

    init(item: CachedItem) {
        ocId = item.ocId
        account = item.account
        isDirectory = item.isDirectory
        fileName = item.fileName
        fileId = item.fileId
        etag = item.etag
        hasPreview = item.hasPreview
        width = item.width
        height = item.height
        fullPath = item.fullPath
        coverTiles = item.isDirectory ? item.coverTiles : []
    }

    /// Memberwise initializer (the cache-backed `init(item:)` above suppresses the
    /// synthesized one). Lets other sources — e.g. live server entries mapped in
    /// ``GridItemSnapshot/init(file:account:)`` — build a snapshot directly.
    init(
        ocId: String, account: String, isDirectory: Bool, fileName: String,
        fileId: String, etag: String, hasPreview: Bool, width: Int, height: Int,
        fullPath: String, coverTiles: [CoverTile]
    ) {
        self.ocId = ocId
        self.account = account
        self.isDirectory = isDirectory
        self.fileName = fileName
        self.fileId = fileId
        self.etag = etag
        self.hasPreview = hasPreview
        self.width = width
        self.height = height
        self.fullPath = fullPath
        self.coverTiles = coverTiles
    }
}

extension PhotoItem {
    /// Builds a viewer photo item from a grid snapshot (photos only).
    init(snapshot: GridItemSnapshot) {
        self.init(
            ocId: snapshot.ocId,
            fileId: snapshot.fileId,
            etag: snapshot.etag,
            fileName: snapshot.fileName,
            serverPath: snapshot.fullPath,
            width: snapshot.width,
            height: snapshot.height
        )
    }
}
