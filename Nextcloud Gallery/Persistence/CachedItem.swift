//
//  CachedItem.swift
//  Nextcloud Gallery
//
//  A cached photo or folder entry mirroring a server NKFile.
//

import Foundation
import SwiftData
import NextcloudKit

/// One cached node of the remote tree (a photo or a folder). Stored flat: a
/// folder's children are found by querying `parentPath == <folder full path>`.
///
/// `nonisolated` so the background `@ModelActor` (``CacheStore``) can create and
/// mutate instances; the project otherwise defaults declarations to `@MainActor`.
@Model
nonisolated final class CachedItem {
    // Covers the hot read paths so they're index lookups, not full-table scans of
    // the whole (multi-folder) library, which otherwise grow linearly with it:
    //  - `[account, parentPath]`            → a folder's direct children
    //    (`children`, `folderItems`, `hasSubfolders`, `gridThumbnailTargets`).
    //  - `[account, classFile, parentPath]` → images under a subtree, where the
    //    trailing `parentPath` serves both `== base` and `starts(with:)` range
    //    scans (`flatItems`, `pruneMissingImages`).
    //  - `[account, fullPath]`              → a folder's own cached row
    //    (`cachedFolderItem`).
    #Index<CachedItem>(
        [\.account, \.parentPath],
        [\.account, \.classFile, \.parentPath],
        [\.account, \.fullPath]
    )

    /// Globally unique server id for this instance — the upsert key.
    @Attribute(.unique) var ocId: String
    var account: String
    /// Normalized full path of the containing folder (matches `NKFile.serverUrl`).
    var parentPath: String
    var fileName: String
    /// Lowercased name for case-insensitive sorting.
    var nameKey: String
    /// Normalized full path of this item (`parentPath` + "/" + `fileName`).
    var fullPath: String
    var isDirectory: Bool
    /// Sort rank so folders come before photos (0 = folder, 1 = photo).
    var kindRank: Int
    /// Numeric server file id used by the preview endpoint (string-typed).
    var fileId: String
    var etag: String
    var contentType: String
    /// NextcloudKit class, e.g. "image", "video", "directory".
    var classFile: String
    var size: Int64
    var date: Date
    var hasPreview: Bool
    var width: Int
    var height: Int
    /// For directory items: up to 4 representative tiles for the 2x2 cover,
    /// denormalized from ``FolderState`` so the grid renders covers straight from
    /// its single child query, with no per-cell lookup. Always empty for photos.
    var coverTiles: [CoverTile] = []

    init(
        ocId: String,
        account: String,
        parentPath: String,
        fileName: String,
        fullPath: String,
        isDirectory: Bool,
        fileId: String,
        etag: String,
        contentType: String,
        classFile: String,
        size: Int64,
        date: Date,
        hasPreview: Bool,
        width: Int,
        height: Int
    ) {
        self.ocId = ocId
        self.account = account
        self.parentPath = parentPath
        self.fileName = fileName
        self.nameKey = fileName.lowercased()
        self.fullPath = fullPath
        self.isDirectory = isDirectory
        self.kindRank = isDirectory ? 0 : 1
        self.fileId = fileId
        self.etag = etag
        self.contentType = contentType
        self.classFile = classFile
        self.size = size
        self.date = date
        self.hasPreview = hasPreview
        self.width = width
        self.height = height
    }

    /// True for items we treat as photos in the gallery.
    var isPhoto: Bool { classFile == "image" }
}

extension CachedItem {
    /// Builds a cached item from a server file.
    convenience init(file: NKFile, parentPath: String, fullPath: String, account: String) {
        self.init(
            ocId: file.ocId,
            account: account,
            parentPath: parentPath,
            fileName: file.fileName,
            fullPath: fullPath,
            isDirectory: file.directory,
            fileId: file.fileId,
            etag: file.etag,
            contentType: file.contentType,
            classFile: file.classFile,
            size: file.size,
            date: file.date,
            hasPreview: file.hasPreview,
            width: Int(file.width),
            height: Int(file.height)
        )
    }

    /// Updates the mutable fields of an existing cached item from a fresh listing.
    /// Every assignment guards against a no-op write because each one is observed
    /// by `@Query`, and routine re-listings rarely change anything.
    func apply(file: NKFile, parentPath: String, fullPath: String, account: String) {
        if self.account != account { self.account = account }
        if self.parentPath != parentPath { self.parentPath = parentPath }
        if self.fileName != file.fileName {
            self.fileName = file.fileName
            self.nameKey = file.fileName.lowercased()
        }
        if self.fullPath != fullPath { self.fullPath = fullPath }
        if self.isDirectory != file.directory {
            self.isDirectory = file.directory
            self.kindRank = file.directory ? 0 : 1
        }
        if self.fileId != file.fileId { self.fileId = file.fileId }
        if self.etag != file.etag { self.etag = file.etag }
        if self.contentType != file.contentType { self.contentType = file.contentType }
        if self.classFile != file.classFile { self.classFile = file.classFile }
        if self.size != file.size { self.size = file.size }
        if self.date != file.date { self.date = file.date }
        if self.hasPreview != file.hasPreview { self.hasPreview = file.hasPreview }
        let newWidth = Int(file.width)
        if self.width != newWidth { self.width = newWidth }
        let newHeight = Int(file.height)
        if self.height != newHeight { self.height = newHeight }
    }
}
