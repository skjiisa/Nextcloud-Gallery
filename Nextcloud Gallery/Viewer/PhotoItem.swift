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
    /// Stored pixel dimensions (0 if unknown). Used to size the filmstrip cell and
    /// compute the viewer's aspect-fit frame before any image has loaded.
    let width: Int
    let height: Int

    var id: String { ocId }

    /// The photo's aspect ratio from its stored dimensions (square fallback).
    var aspectRatio: CGFloat {
        width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : 1
    }

    init(ocId: String, fileId: String, etag: String, fileName: String, serverPath: String, width: Int = 0, height: Int = 0) {
        self.ocId = ocId
        self.fileId = fileId
        self.etag = etag
        self.fileName = fileName
        self.serverPath = serverPath
        self.width = width
        self.height = height
    }

    init(cachedItem: CachedItem) {
        ocId = cachedItem.ocId
        fileId = cachedItem.fileId
        etag = cachedItem.etag
        fileName = cachedItem.fileName
        serverPath = cachedItem.fullPath
        width = cachedItem.width
        height = cachedItem.height
    }
}
