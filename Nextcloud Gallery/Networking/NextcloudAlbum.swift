//
//  NextcloudAlbum.swift
//  Nextcloud Gallery
//
//  A Nextcloud Photos album. NextcloudKit has no album support, so albums are read
//  from the raw `/remote.php/dav/photos/<user>/albums/` WebDAV tree (see
//  ``NextcloudClient`` albums extension). This is the value type the UI renders.
//

import Foundation

/// One Photos album: its display name, the WebDAV collection it lives at, how many
/// photos the server reports, and the file id of its cover photo (`nc:last-photo`).
///
/// `nonisolated` immutable value data so it crosses actor boundaries freely and is
/// `Codable` for persisting an open album level in a tab's restore stack.
nonisolated struct Album: Hashable, Sendable, Codable, Identifiable {
    /// Display name — the album collection's folder name, URL-decoded.
    let name: String
    /// Absolute WebDAV URL of the album collection (already percent-encoded by the
    /// server). Used directly to PROPFIND the album's photos.
    let davPath: String
    /// Number of photos the server reports for the album (`nc:nbItems`).
    let photoCount: Int
    /// File id of the album's cover photo (`nc:last-photo`), if the album has one.
    /// The cover thumbnail loads by file id alone (preview-by-id ignores the etag).
    let coverFileId: String?

    var id: String { davPath }
}
