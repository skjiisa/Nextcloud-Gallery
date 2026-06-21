//
//  NKFile+Snapshot.swift
//  Nextcloud Gallery
//
//  Maps a live NextcloudKit server entry into the cache-free value types the grids
//  and viewer render. Favorites and resolved album photos arrive as `NKFile`s that
//  are never written to the SwiftData cache (they aren't part of the folder tree),
//  so they're projected straight into ``GridItemSnapshot`` here.
//

import Foundation
import NextcloudKit

extension GridItemSnapshot {
    /// Builds a snapshot from a live server entry (a favorite, a resolved album photo,
    /// or a favorited folder). `coverTiles` is the folder's 2x2 cover when known.
    init(file: NKFile, account: String, coverTiles: [CoverTile] = []) {
        self.init(
            ocId: file.ocId,
            account: account,
            isDirectory: file.directory,
            fileName: file.fileName,
            fileId: file.fileId,
            etag: file.etag,
            hasPreview: file.hasPreview,
            width: Int(file.width),
            height: Int(file.height),
            fullPath: WebDAVPath.normalized(file.serverUrl + "/" + file.fileName),
            coverTiles: coverTiles
        )
    }

    /// A copy with `coverTiles` replaced — lets a folder snapshot (built off a
    /// non-Sendable `NKFile`) gain its cover after a concurrent fetch.
    func withCoverTiles(_ coverTiles: [CoverTile]) -> GridItemSnapshot {
        GridItemSnapshot(
            ocId: ocId, account: account, isDirectory: isDirectory, fileName: fileName,
            fileId: fileId, etag: etag, hasPreview: hasPreview, width: width, height: height,
            fullPath: fullPath, coverTiles: coverTiles
        )
    }
}
