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
    case xsmall = 0  // most columns, smallest photos
    case small
    case regular
    case medium
    case large
    case single      // one big photo per row

    var id: Int { rawValue }

    /// Multiplier on the size class's base `minGridCellSize`, so the column count
    /// stays responsive across iPhone/iPad while honoring the chosen density. The
    /// gaps are tuned so each step changes the phone column count by ~1 (≈6→5→4→3→
    /// 2→1) instead of skipping levels.
    var cellSizeMultiplier: CGFloat {
        switch self {
        case .xsmall: 0.6
        case .small: 0.72
        case .regular: 0.88
        case .medium: 1.0
        case .large: 1.45
        case .single: 3.0
        }
    }

    /// Tile corner radius, scaled to the cell size for a native-Photos feel:
    /// tight on small tiles, a touch rounder on large ones.
    var cornerRadius: CGFloat {
        switch self {
        case .xsmall: 2
        case .small: 3
        case .regular: 4
        case .medium: 5
        case .large: 8
        case .single: 12
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
