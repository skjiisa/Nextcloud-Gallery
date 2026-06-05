//
//  FolderRoute.swift
//  Nextcloud Gallery
//
//  Navigation value for drilling into a folder.
//

import Foundation

/// Identifies a folder to push onto the navigation stack.
nonisolated struct FolderRoute: Hashable {
    let folderPath: String
    let title: String
    let account: String
}
