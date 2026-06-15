//
//  GallerySortOrder.swift
//  Nextcloud Gallery
//
//  How a flattened gallery orders its photos. One case for now (newest first);
//  the abstraction exists so other orders drop in without touching the view.
//

import Foundation
import SwiftData

/// A sort order for the flattened gallery. Add a case here and a branch in
/// ``sortDescriptors`` (and, later, a menu entry) to introduce a new order.
nonisolated enum GallerySortOrder: String, CaseIterable, Identifiable, Sendable {
    /// Newest modification date first — matches the official app's gallery tab.
    case newestFirst

    var id: String { rawValue }

    /// The descriptors applied to the gallery's `@Query`. The trailing name tie-break
    /// keeps ordering stable when two photos share a timestamp.
    var sortDescriptors: [SortDescriptor<CachedItem>] {
        switch self {
        case .newestFirst:
            [SortDescriptor(\.date, order: .reverse), SortDescriptor(\.nameKey)]
        }
    }
}
