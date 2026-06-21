//
//  NextcloudClient+Covers.swift
//  Nextcloud Gallery
//
//  Fetching representative cover photos for things that don't carry one — favorited
//  folders (a 2x2 composite) and the Media folder (a single thumbnail on its buttons).
//

import Foundation
import NextcloudKit

extension NextcloudClient {
    /// Up to `limit` representative photos for a folder's cover (newest first in its
    /// subtree), as ``CoverTile``s ready for the thumbnail pipeline.
    func folderCoverTiles(path: String, limit: Int = 4) async throws -> [CoverTile] {
        let files = try await searchMedia(under: path, limit: limit)
        return files.prefix(limit).map { CoverTile(ocId: $0.ocId, fileId: $0.fileId, etag: $0.etag) }
    }
}
