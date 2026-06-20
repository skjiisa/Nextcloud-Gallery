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

    /// Marks the file at `serverPath` (a full Files-DAV URL) as a favorite or not.
    /// NextcloudKit wants a path relative to the user's Files root, so the root prefix
    /// is stripped here.
    func setFavorite(serverPath: String, favorite: Bool) async throws {
        let result = await NextcloudKit.shared.setFavoriteAsync(
            fileName: filesRootRelativePath(serverPath),
            favorite: favorite,
            account: credentials.account
        )
        guard result.error == .success else { throw GalleryError(result.error) }
    }

    /// Drops the `…/remote.php/dav/files/<userId>/` prefix from a full server path,
    /// leaving the path NextcloudKit's file APIs expect (it re-adds the prefix).
    func filesRootRelativePath(_ serverPath: String) -> String {
        let root = WebDAVPath.normalized(filesRootPath) + "/"
        let normalized = WebDAVPath.normalized(serverPath)
        return normalized.hasPrefix(root) ? String(normalized.dropFirst(root.count)) : normalized
    }
}
