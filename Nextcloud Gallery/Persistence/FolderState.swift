//
//  FolderState.swift
//  Nextcloud Gallery
//
//  Per-folder crawl + cover state for warming and 2x2 covers.
//

import Foundation
import SwiftData

/// Tracks, for each folder, where it is in the warming crawl and which photos
/// represent it in a 2x2 cover. Separate from ``CachedItem`` because not every
/// cached item is a folder and this row carries crawl bookkeeping.
@Model
nonisolated final class FolderState {
    // Covers the warming-crawl claim/count queries so they don't scan every folder
    // row. Both lead with `[account, listStateRaw]` (the equality filter) and trail
    // with `depth` (the sort), matching `claimNextPending`/`claimNextNeedingThumbnails`
    // and the `pending`/`reset`/`folderCount` queries.
    #Index<FolderState>(
        [\.account, \.listStateRaw, \.depth],
        [\.account, \.listStateRaw, \.thumbnailsReady, \.depth]
    )

    /// Normalized full path of the folder — the upsert key.
    @Attribute(.unique) var folderPath: String
    var account: String
    /// The folder's etag at last listing; a change means re-crawl.
    var etag: String
    /// Crawl state, stored as a raw string so it's usable in `#Predicate`.
    var listStateRaw: String
    /// Depth from the root, for breadth-first crawl ordering.
    var depth: Int
    /// Chosen representative photo tiles for the 2x2 cover (up to 4).
    var coverTiles: [CoverTile]
    /// True once the cover is final (4 tiles, or the subtree is fully crawled).
    var coverResolved: Bool
    /// True once the trailing thumbnail crawler has prefetched this folder's cover
    /// tiles and its photos' grid thumbnails. Lets thumbnailing resume across
    /// launches and trail discovery without re-scanning finished folders.
    var thumbnailsReady: Bool
    var lastListed: Date?

    /// Typed accessor over ``listStateRaw``.
    var listState: ListState {
        get { ListState(rawValue: listStateRaw) ?? .pending }
        set { listStateRaw = newValue.rawValue }
    }

    init(
        folderPath: String,
        account: String,
        etag: String = "",
        listState: ListState = .pending,
        depth: Int = 0,
        coverTiles: [CoverTile] = [],
        coverResolved: Bool = false,
        thumbnailsReady: Bool = false,
        lastListed: Date? = nil
    ) {
        self.folderPath = folderPath
        self.account = account
        self.etag = etag
        self.listStateRaw = listState.rawValue
        self.depth = depth
        self.coverTiles = coverTiles
        self.coverResolved = coverResolved
        self.thumbnailsReady = thumbnailsReady
        self.lastListed = lastListed
    }
}
