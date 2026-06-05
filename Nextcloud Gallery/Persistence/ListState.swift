//
//  ListState.swift
//  Nextcloud Gallery
//
//  Crawl state for a folder in the resumable warming pipeline.
//

import Foundation

/// Where a folder sits in the breadth-first warming crawl.
///
/// `pending` → not yet listed; `claimed` → a worker is listing it right now
/// (transient; reset to `pending` on launch in case of a crash); `listed` → its
/// children are cached.
nonisolated enum ListState: String, Codable, Sendable {
    case pending
    case claimed
    case listed
}
