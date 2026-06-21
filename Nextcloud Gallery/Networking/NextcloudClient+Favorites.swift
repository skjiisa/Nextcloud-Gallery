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
    /// The account's favorites as cache-free snapshots: favorited folders first (by
    /// name), then favorited photos (newest first). Non-image, non-folder favorites are
    /// dropped (this is a photo gallery).
    func favorites(queue: DispatchQueue = .main) async throws -> [GridItemSnapshot] {
        let options = NKRequestOptions(queue: queue)
        let result = await NextcloudKit.shared.listingFavoritesAsync(
            showHiddenFiles: false,
            account: credentials.account,
            options: options
        )
        guard result.error == .success else { throw GalleryError(result.error) }
        let account = credentials.account
        let files = (result.files ?? [])
            .filter { $0.directory || ($0.hasPreview && $0.classFile == NKTypeClassFile.image.rawValue) }
            .sorted { a, b in
                if a.directory != b.directory { return a.directory }   // folders first
                return a.directory ? a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
                                   : a.date > b.date
            }

        // Build the Sendable snapshots up front (NKFile isn't Sendable), then fetch a
        // cover for each favorited folder concurrently and attach it.
        return await withTaskGroup(of: (Int, GridItemSnapshot).self) { group in
            for (index, file) in files.enumerated() {
                let snapshot = GridItemSnapshot(file: file, account: account)
                let coverPath = file.directory ? snapshot.fullPath : nil
                group.addTask {
                    guard let coverPath else { return (index, snapshot) }
                    let tiles = (try? await self.folderCoverTiles(path: coverPath, limit: 4)) ?? []
                    return (index, snapshot.withCoverTiles(tiles))
                }
            }
            var collected: [(Int, GridItemSnapshot)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
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
