//
//  DiskCacheReaper.swift
//  Nextcloud Gallery
//
//  Bounds an on-disk media cache by evicting least-recently-modified files.
//

import Foundation

/// Keeps a cache directory under a size budget by deleting the oldest files first.
/// Used by the thumbnail and full-image caches so a warmed library can't grow
/// without limit.
nonisolated enum DiskCacheReaper {
    /// Removes every file in the cache directory, leaving the directory itself in
    /// place so the store can keep writing into it.
    static func clear(directory: URL) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }

    static func reap(directory: URL, maxBytes: Int) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }

        var files = urls.compactMap { url -> (url: URL, size: Int, modified: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }

        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }

        files.sort { $0.modified < $1.modified } // oldest first
        for file in files {
            if total <= maxBytes { break }
            try? fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }
}
