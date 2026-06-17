//
//  GalleryGridZoom.swift
//  Nextcloud Gallery
//
//  Discrete zoom levels for the flattened gallery grid, cycled from the nav bar.
//

import Foundation

/// How densely the flattened gallery packs its photos. Lower levels show more,
/// smaller tiles; higher levels show fewer, larger ones — the nav-bar button
/// cycles through them. Add a case (and a branch below) to introduce a level.
nonisolated enum GalleryGridZoom: Int, CaseIterable, Identifiable, Codable, Sendable {
    case dense = 0   // most columns, smallest photos
    case medium
    case large
    case single      // one big photo per row

    var id: Int { rawValue }

    /// Multiplier on the size class's base `minGridCellSize`, so the column count
    /// stays responsive across iPhone/iPad while honoring the chosen density.
    var cellSizeMultiplier: CGFloat {
        switch self {
        case .dense: 0.6
        case .medium: 1.0
        case .large: 1.7
        case .single: 3.0
        }
    }

    /// Tile corner radius, scaled to the cell size for a native-Photos feel:
    /// tight on small tiles, a touch rounder on large ones.
    var cornerRadius: CGFloat {
        switch self {
        case .dense: 2
        case .medium: 4
        case .large: 7
        case .single: 10
        }
    }

    /// One step toward larger photos / fewer columns (clamped at the top level).
    var zoomedIn: GalleryGridZoom { GalleryGridZoom(rawValue: rawValue + 1) ?? self }
    /// One step toward smaller photos / more columns (clamped at the bottom level).
    var zoomedOut: GalleryGridZoom { GalleryGridZoom(rawValue: rawValue - 1) ?? self }

    /// Whether there's a larger / smaller level to move to (for disabling buttons).
    var canZoomIn: Bool { GalleryGridZoom(rawValue: rawValue + 1) != nil }
    var canZoomOut: Bool { GalleryGridZoom(rawValue: rawValue - 1) != nil }
}
