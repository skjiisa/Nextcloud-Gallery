//
//  LayoutMetrics.swift
//  Nextcloud Gallery
//
//  Size-class-aware layout metrics: the single source of truth for grid sizing,
//  spacing, and readable widths so iPhone, iPad (including resized and
//  multitasking windows), and visionOS share consistent proportions.
//
//  Injected once near the root from the window's horizontal size class (see
//  `RootView`) and read elsewhere via `@Environment(\.layoutMetrics)`. New
//  cross-platform features should pull their dimensions from here rather than
//  hard-coding point values, so they adapt as the canvas grows.
//

import SwiftUI

struct LayoutMetricsEnvironmentKey: EnvironmentKey {
    static let defaultValue = LayoutMetrics()
}

extension EnvironmentValues {
    /// Size-class-aware layout metrics for the current window.
    var layoutMetrics: LayoutMetrics {
        get { self[LayoutMetricsEnvironmentKey.self] }
        set { self[LayoutMetricsEnvironmentKey.self] = newValue }
    }
}

/// Responsive layout metrics derived from the horizontal size class.
///
/// `Equatable` so re-injecting a freshly-built value into the environment never
/// invalidates descendants (including every grid cell) unless the metrics
/// actually changed — i.e. only across a compact/regular transition when a
/// window is resized.
struct LayoutMetrics: Equatable {
    /// Spacing between major sections (e.g. the sign-in hero and the fields).
    let majorSpacing: CGFloat
    /// Spacing between controls within a section.
    let controlSpacing: CGFloat
    /// Padding around the edges of scrollable content.
    let contentPadding: CGFloat
    /// Inter-tile spacing within gallery grids (kept tight, Photos-style).
    let gridSpacing: CGFloat
    /// Minimum square tile size before a grid reflows to fewer columns. Larger on
    /// roomy canvases so thumbnails stay legible instead of shrinking to iPhone
    /// proportions on a much bigger display.
    let minGridCellSize: CGFloat
    /// Size of large hero glyphs (e.g. the sign-in icon).
    let largeIconSize: CGFloat
    /// Max width for single-column "form" content so it sits as a centered card
    /// on wide iPad / visionOS windows instead of stretching edge to edge.
    let maxReadableWidth: CGFloat?

    /// Corner radius for square grid tiles. Constant across size classes, so it's
    /// a static constant rather than a per-instance metric — lets lightweight
    /// cells reference it without reading the environment.
    static let tileCornerRadius: CGFloat = 8

    init(sizeClass: UserInterfaceSizeClass? = nil) {
        if sizeClass == .regular {
            // iPad (full / half-screen), visionOS, and other roomy canvases.
            majorSpacing = 32
            controlSpacing = 16
            contentPadding = 16
            gridSpacing = 3
            minGridCellSize = 150
            largeIconSize = 84
            maxReadableWidth = 500
        } else {
            // iPhone and compact-width multitasking windows.
            majorSpacing = 24
            controlSpacing = 12
            contentPadding = 8
            gridSpacing = 3
            minGridCellSize = 110
            largeIconSize = 64
            maxReadableWidth = nil
        }
    }
}
