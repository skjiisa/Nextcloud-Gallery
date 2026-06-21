//
//  NextcloudClient+ItemMetadata.swift
//  Nextcloud Gallery
//
//  Fetching a single item's mutable metadata (favorite flag + assigned system tags)
//  on demand. The grids/viewer carry only the immutable bits in their value
//  snapshots, so the action surfaces (favorite toggle, tag editor) read the current
//  state straight from the server when a photo is opened — no cache schema change.
//

import Foundation
import NextcloudKit

/// A photo's current server-side metadata, as Sendable value data. `NKTag` is itself
/// Sendable, so this crosses actor boundaries freely.
nonisolated struct PhotoMetadata: Sendable {
    let fileId: String
    let isFavorite: Bool
    let tags: [NKTag]
}

extension NextcloudClient {
    /// Reads the favorite flag and assigned tags for the file at `serverPath` (a full
    /// Files-DAV URL) via a depth-0 PROPFIND. The default property set includes
    /// `oc:favorite` and `nc:system-tags`, so one request covers both.
    func fileMetadata(serverPath: String) async throws -> PhotoMetadata {
        let result = await NextcloudKit.shared.readFileOrFolderAsync(
            serverUrlFileName: serverPath,
            depth: "0",
            account: credentials.account
        )
        guard result.error == .success, let file = result.files?.first else {
            throw GalleryError(result.error)
        }
        return PhotoMetadata(fileId: file.fileId, isFavorite: file.favorite, tags: file.tags)
    }
}
