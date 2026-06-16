//
//  GallerySortOrder.swift
//  Nextcloud Gallery
//
//  How a flattened gallery orders its photos. One case for now (newest first);
//  the abstraction exists so other orders drop in without touching the view.
//

import Foundation
import SwiftData

/// A sort order for the flattened gallery, selectable from the nav bar. Add a
/// case here, a branch in ``sortDescriptors``, and a `label`/`symbol` to introduce
/// a new order — the picker is built from `allCases`.
nonisolated enum GallerySortOrder: String, CaseIterable, Identifiable, Sendable {
    /// Newest modification date first — matches the official app's gallery tab.
    case newestFirst
    /// The order photos appear when browsing the folder tree, flattened: grouped
    /// by their containing folder (in path order), alphabetical within each.
    case folderOrder

    var id: String { rawValue }

    /// Menu label for this order.
    var label: String {
        switch self {
        case .newestFirst: "Most Recent"
        case .folderOrder: "Folder Order"
        }
    }

    /// Menu icon for this order.
    var symbol: String {
        switch self {
        case .newestFirst: "clock"
        case .folderOrder: "folder"
        }
    }

    /// The descriptors applied to the gallery's `@Query`. The trailing `nameKey`
    /// tie-break keeps ordering stable (and case-insensitive within a folder).
    var sortDescriptors: [SortDescriptor<CachedItem>] {
        switch self {
        case .newestFirst:
            [SortDescriptor(\.date, order: .reverse), SortDescriptor(\.nameKey)]
        case .folderOrder:
            [SortDescriptor(\.parentPath), SortDescriptor(\.nameKey)]
        }
    }
}
