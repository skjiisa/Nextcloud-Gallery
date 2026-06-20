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

extension NextcloudClient {
    /// All system tags defined on the account (`NKTag` is Sendable: id, name, color).
    func availableTags() async throws -> [NKTag] {
        let result = await NextcloudKit.shared.getTags(account: credentials.account)
        guard result.error == .success else { throw GalleryError(result.error) }
        return result.tags ?? []
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
