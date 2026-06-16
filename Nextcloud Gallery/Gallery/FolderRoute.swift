//
//  FolderRoute.swift
//  Nextcloud Gallery
//
//  Navigation value for drilling into a folder.
//

import Foundation

/// Identifies a folder to push onto the navigation stack. `Codable` so a tab's
/// browse stack can be serialized and restored across launches (see ``BrowseTab``).
nonisolated struct FolderRoute: Hashable, Codable {
    let folderPath: String
    let title: String
    let account: String
}
