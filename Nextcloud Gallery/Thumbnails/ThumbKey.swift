//
//  ThumbKey.swift
//  Nextcloud Gallery
//
//  Identity + filename for a cached thumbnail.
//

import Foundation

/// Identifies a cached thumbnail by item, version, and size. Including the etag
/// means a changed file naturally maps to a new key (and a new file), so stale
/// thumbnails are bypassed automatically.
nonisolated struct ThumbKey: Hashable, Sendable {
    let ocId: String
    let etag: String
    let pixels: Int

    /// Stable identifier for in-flight de-duplication and `.task(id:)`.
    var id: String { "\(ocId)_\(etag)_\(pixels)" }

    /// Filesystem-safe filename for the on-disk cache.
    var fileName: String {
        let safeEtag = etag.replacing("/", with: "-").replacing("\"", with: "")
        return "\(ocId)_\(safeEtag)_\(pixels).jpg"
    }
}
