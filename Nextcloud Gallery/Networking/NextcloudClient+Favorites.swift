//
//  NextcloudClient+Favorites.swift
//  Nextcloud Gallery
//
//  Reading the account's Nextcloud favorites. Unlike albums, favorites are a
//  first-class NextcloudKit feature (a WebDAV REPORT), so the entries come back as
//  real `NKFile`s with their true path/ocId/etag — no resolution needed.
//

import Foundation
import NextcloudKit

extension NextcloudClient {
    /// The account's favorited photos, newest first, as cache-free snapshots.
    /// Folders and non-image favorites are dropped (this is a photo gallery).
    func favorites(queue: DispatchQueue = .main) async throws -> [GridItemSnapshot] {
        let options = NKRequestOptions(queue: queue)
        let result = await NextcloudKit.shared.listingFavoritesAsync(
            showHiddenFiles: false,
            account: credentials.account,
            options: options
        )
        guard result.error == .success else { throw GalleryError(result.error) }
        let account = credentials.account
        return (result.files ?? [])
            .filter { !$0.directory && $0.hasPreview && $0.classFile == NKTypeClassFile.image.rawValue }
            .sorted { $0.date > $1.date }
            .map { GridItemSnapshot(file: $0, account: account) }
    }
}
