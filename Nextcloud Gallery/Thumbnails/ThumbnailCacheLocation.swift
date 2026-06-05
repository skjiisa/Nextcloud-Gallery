//
//  ThumbnailCacheLocation.swift
//  Nextcloud Gallery
//
//  On-disk location for cached thumbnails.
//

import Foundation

/// Resolves on-disk paths for cached thumbnails under Application Support. The
/// directory is excluded from backup (thumbnails are re-downloadable) but, unlike
/// Caches, won't be purged out from under a warmed library.
nonisolated struct ThumbnailCacheLocation {
    let directory: URL

    init() {
        var base = URL.applicationSupportDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)
        directory = base
    }

    func fileURL(for key: ThumbKey) -> URL {
        directory.appending(path: key.fileName)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
