//
//  NextcloudAlbum.swift
//  Nextcloud Gallery
//
//  A Nextcloud Photos album, as the UI renders it. Built from NextcloudKit's
//  `NKPhotoAlbum` (see ``NextcloudClient`` albums extension).
//

import Foundation

/// One Photos album: its name (which is also its identity on the server — every
/// album operation addresses it by name), how many photos the server reports, and
/// the file id of its cover photo (`nc:last-photo`).
///
/// `nonisolated` immutable value data so it crosses actor boundaries freely.
nonisolated struct Album: Hashable, Sendable, Identifiable {
    /// Display name — the album collection's folder name, URL-decoded.
    let name: String
    /// Number of photos the server reports for the album (`nc:nbItems`).
    let photoCount: Int
    /// File id of the album's cover photo (`nc:last-photo`), if the album has one.
    /// The cover thumbnail loads by file id alone (preview-by-id ignores the etag).
    let coverFileId: String?

    var id: String { name }
}
