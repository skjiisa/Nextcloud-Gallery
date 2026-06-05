//
//  FolderDTO.swift
//  Nextcloud Gallery
//
//  Sendable snapshot of a folder, passed from the CacheStore actor to the
//  warming coordinator.
//

import Foundation

/// A folder to crawl, carried across the actor boundary as plain data.
nonisolated struct FolderDTO: Sendable, Hashable {
    let path: String
    let depth: Int
    let etag: String
}
