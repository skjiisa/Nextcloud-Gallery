//
//  LayoutMetrics.swift
//  Nextcloud Gallery
//
//  Size-class-aware layout metrics: the single source of truth for grid sizing,
//  spacing, and readable widths so iPhone, iPad (including resized and
//  multitasking windows), and visionOS share consistent proportions.
//
//  Built from a view's `traitCollection.horizontalSizeClass` (UIKit) and re-derived
//  whenever a controller's traits change. Pull new cross-platform dimensions from
//  here rather than hard-coding point values, so they adapt as the canvas grows.
//

import UIKit

/// Responsive layout metrics derived from the horizontal size class.
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

    /// Corner radius for square grid tiles. Constant across size classes.
    static let tileCornerRadius: CGFloat = 8

    init(sizeClass: UIUserInterfaceSizeClass = .unspecified) {
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

    /// Convenience: metrics for a view's current traits.
    init(traits: UITraitCollection) {
        self.init(sizeClass: traits.horizontalSizeClass)
    }
}
