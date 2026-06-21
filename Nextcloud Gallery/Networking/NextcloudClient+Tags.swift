//
//  NextcloudClient+Tags.swift
//  Nextcloud Gallery
//
//  Reading and writing Nextcloud system tags — the tags you manage in the web UI's
//  file sidebar. First-class in NextcloudKit (the `systemtags` WebDAV tree), so these
//  are thin wrappers. Tags are assigned to a file by its numeric file id.
//

import Foundation
import NextcloudKit

/// A system tag plus the file id of a representative photo for its cover (nil if the
/// tag has no image). Lets a tag be rendered like an album.
nonisolated struct TagPreview: Sendable, Hashable {
    let tag: NKTag
    let coverFileId: String?
}

extension NextcloudClient {
    /// All system tags defined on the account (`NKTag` is Sendable: id, name, color).
    func availableTags() async throws -> [NKTag] {
        let result = await NextcloudKit.shared.getTags(account: credentials.account)
        guard result.error == .success else { throw GalleryError(result.error) }
        return result.tags ?? []
    }

    /// All system tags, each paired with a cover photo's file id (fetched concurrently).
    func tagPreviews() async throws -> [TagPreview] {
        let tags = try await availableTags()
        return await withTaskGroup(of: (Int, TagPreview).self) { group in
            for (index, tag) in tags.enumerated() {
                group.addTask {
                    let cover = try? await self.tagCoverFileId(tagId: tag.id)
                    return (index, TagPreview(tag: tag, coverFileId: cover))
                }
            }
            var collected: [(Int, TagPreview)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Creates a new system tag (does not assign it to anything).
    func createTag(named name: String) async throws {
        let result = await NextcloudKit.shared.createTag(name: name, account: credentials.account)
        guard result.error == .success else { throw GalleryError(result.error) }
    }

    /// Assigns an existing tag to a file.
    func addTag(_ tagId: String, toFileId fileId: String) async throws {
        let result = await NextcloudKit.shared.addTagToFile(tagId: tagId, fileId: fileId, account: credentials.account)
        guard result.error == .success else { throw GalleryError(result.error) }
    }

    /// Removes a tag assignment from a file.
    func removeTag(_ tagId: String, fromFileId fileId: String) async throws {
        let result = await NextcloudKit.shared.removeTagFromFile(tagId: tagId, fileId: fileId, account: credentials.account)
        guard result.error == .success else { throw GalleryError(result.error) }
    }
}
