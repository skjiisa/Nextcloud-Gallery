//
//  NextcloudConfig.swift
//  Nextcloud Gallery
//
//  Central configuration + one-time NextcloudKit setup.
//

import Foundation
import NextcloudKit

/// App-wide constants and the single entry point for configuring NextcloudKit.
///
/// `nonisolated` so the constants are reachable from background actors (the
/// warming crawler and thumbnail pipeline) without hopping to the main actor.
nonisolated enum NextcloudConfig {
    /// Shown to the user on the Nextcloud "Grant access" page and used to name
    /// the generated app password in the server's security settings.
    static let userAgent = "Nextcloud Gallery (iOS)"

    /// NextcloudKit requires a non-optional group identifier. We have no app
    /// group, so the bundle id is used purely to namespace NextcloudKit's own
    /// internal bookkeeping. It must match between `setup` and `appendSession`.
    static let groupIdentifier = Bundle.main.bundleIdentifier ?? "app.lyons.Nextcloud-Gallery"

    /// Max parallel connections per host for the underlying session.
    static let httpMaximumConnectionsPerHost = 6

    // MARK: Preview pixel sizes (square, server-cropped "cover")

    /// Tile size for the 2x2 folder cover composites.
    static let coverTilePixels = 384
    /// Thumbnail size for individual photo grid cells.
    static let gridThumbnailPixels = 512
    /// Larger preview shown first in the full-screen viewer before the full file.
    static let viewerPreviewPixels = 1024

    /// How many of a folder's own photos the trailing thumbnail crawler prefetches
    /// at grid size ahead of viewing. The rest load on demand as the user scrolls,
    /// so this stays bounded for huge folders.
    static let gridThumbnailPrefetchLimit = 30

    /// Max thumbnail downloads in flight at once (across visible cells, grid
    /// prefetch, and warming), gated by ``ThumbnailDownloadGate`` so visible cells
    /// outrank the rest. Kept at `httpMaximumConnectionsPerHost` so this gate, not
    /// URLSession's unordered connection queue, decides what loads next.
    static let maxConcurrentThumbnailDownloads = 6

    /// Max results requested from a flattened-gallery media SEARCH. Generous so a
    /// single request covers typical libraries; date-windowed pagination can be
    /// added later for very large folders.
    static let mediaSearchLimit = 5000

    // MARK: Disk cache budgets

    /// Max bytes kept for the thumbnail cache (oldest evicted beyond this).
    static let thumbnailCacheBudgetBytes = 500 * 1024 * 1024
    /// Max bytes kept for the original-file cache.
    static let fullImageCacheBudgetBytes = 1024 * 1024 * 1024

    /// Configure NextcloudKit. Call once, early, on launch.
    static func configure() {
        NextcloudKit.shared.setup(groupIdentifier: groupIdentifier, delegate: nil)
    }
}
