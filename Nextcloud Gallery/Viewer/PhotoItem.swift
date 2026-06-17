//
//  PhotoItem.swift
//  Nextcloud Gallery
//
//  A lightweight, Sendable snapshot of a photo for the viewer.
//

import Foundation

/// A value snapshot of a photo, decoupled from the `@Model` so the full-screen
/// viewer holds stable data even as the cache mutates underneath it.
nonisolated struct PhotoItem: Identifiable, Hashable, Sendable {
    let ocId: String
    let fileId: String
    let etag: String
    let fileName: String
    /// The WebDAV URL of the file itself, used for full-resolution download.
    let serverPath: String

    var id: String { ocId }

    init(ocId: String, fileId: String, etag: String, fileName: String, serverPath: String) {
        self.ocId = ocId
        self.fileId = fileId
        self.etag = etag
        self.fileName = fileName
        self.serverPath = serverPath
    }

    init(cachedItem: CachedItem) {
        ocId = cachedItem.ocId
        fileId = cachedItem.fileId
        etag = cachedItem.etag
        fileName = cachedItem.fileName
        serverPath = cachedItem.fullPath
    }
}
