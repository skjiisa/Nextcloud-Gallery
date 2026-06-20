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
    /// Builds a photo snapshot from a live server entry (a favorite or a resolved
    /// album photo). Always a photo — no folder cover tiles.
    init(file: NKFile, account: String) {
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
            coverTiles: []
        )
    }
}
