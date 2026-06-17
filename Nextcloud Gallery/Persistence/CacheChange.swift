//
//  CacheChange.swift
//  Nextcloud Gallery
//
//  The cache's change signal. Replaces SwiftUI's `@Query` auto-invalidation: when
//  ``CacheStore`` saves, it posts the set of folder paths whose direct children
//  changed, and each grid re-fetches (off-main) and re-applies its diffable
//  snapshot if its folder — or, for the flattened gallery, its subtree — is among
//  them. NotificationCenter is used because the post originates on the background
//  CacheStore actor; observers register on the main queue.
//

import Foundation

enum CacheChange {
    static let didChange = Notification.Name("app.lyons.Nextcloud-Gallery.CacheStoreDidChange")

    /// userInfo key holding a `Set<String>` of affected parent-folder paths.
    static let parentsKey = "parents"

    /// Posts a change for the given affected parent-folder paths (no-op if empty).
    /// Safe to call from any actor; NotificationCenter handles thread hand-off and
    /// observers receive it on the main queue.
    static func post(parents: Set<String>) {
        guard !parents.isEmpty else { return }
        NotificationCenter.default.post(
            name: didChange, object: nil, userInfo: [parentsKey: parents]
        )
    }

    /// Extracts the affected parent paths from a received notification.
    static func parents(from note: Notification) -> Set<String> {
        note.userInfo?[parentsKey] as? Set<String> ?? []
    }
}
