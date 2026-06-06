//
//  PlatformModifiers.swift
//  Nextcloud Gallery
//
//  Cross-platform view modifiers. The home for treatments that need to differ
//  (or compile out) per platform so feature views stay platform-agnostic.
//

import SwiftUI

extension View {
    /// Standard interaction treatment for a tappable square gallery tile: clips
    /// the hit-test and hover regions to the tile's rounded rectangle and adds
    /// the system hover effect.
    ///
    /// The hover effect is the key cross-platform affordance — it drives visionOS
    /// eye-tracking highlights and iPad/trackpad pointer hover, giving the
    /// otherwise plain-styled cells a sense of interactivity. It is inert on
    /// iPhone, so applying it unconditionally is safe, and it's unavailable on
    /// macOS, so it's compiled out there.
    @ViewBuilder
    func galleryTileInteraction(cornerRadius: CGFloat = LayoutMetrics.tileCornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if os(macOS)
        self.contentShape(shape)
        #else
        self.contentShape(shape)
            .contentShape(.hoverEffect, shape)
            .hoverEffect()
        #endif
    }
}
