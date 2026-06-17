//
//  ImageLoader.swift
//  Nextcloud Gallery
//
//  The grid's thumbnail pipeline for UIKit cells: memory cache → disk
//  (``ThumbnailStore``) → off-main downsample. Replaces SwiftUI's per-cell
//  `.task` loader; cells cancel their in-flight load on reuse and the decoded
//  bitmaps are memoized so re-binding a recycled cell is instant.
//

import UIKit

@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    /// In-memory cache of decoded thumbnails, keyed by ``ThumbKey/id``. Sized
    /// generously; UIKit purges it under memory pressure.
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        return cache
    }()

    private init() {}

    /// A decoded thumbnail already in memory, if any (no disk/network).
    func cachedImage(for key: ThumbKey) -> UIImage? {
        cache.object(forKey: key.id as NSString)
    }

    /// Loads a thumbnail: memory → disk (downloading if needed) → downsample to
    /// `pixels`. Returns nil if the work is cancelled or fails (leaving the cell's
    /// placeholder in place). Decoding runs off the main actor.
    func thumbnail(
        ocId: String,
        fileId: String,
        etag: String,
        pixels: Int,
        store: ThumbnailStore,
        client: NextcloudClient
    ) async -> UIImage? {
        let key = ThumbKey(ocId: ocId, etag: etag, pixels: pixels)
        if let image = cache.object(forKey: key.id as NSString) { return image }

        guard let url = try? await store.load(
            ocId: ocId, fileId: fileId, etag: etag, pixels: pixels, client: client
        ) else { return nil }
        if Task.isCancelled { return nil }

        let maxPixels = pixels
        let output = await Task.detached(priority: .utility) {
            ImageDownsampler.downsample(url: url, maxPixels: maxPixels)
        }.value
        guard let output, !Task.isCancelled else { return nil }

        let image = UIImage(cgImage: output.cgImage)
        cache.setObject(image, forKey: key.id as NSString)
        return image
    }

    /// Best-effort warm of a thumbnail ahead of display (collection-view prefetch).
    /// Skips work already cached; ignores the result.
    func prefetch(
        ocId: String, fileId: String, etag: String, pixels: Int,
        store: ThumbnailStore, client: NextcloudClient
    ) {
        let key = ThumbKey(ocId: ocId, etag: etag, pixels: pixels)
        if cache.object(forKey: key.id as NSString) != nil { return }
        Task { _ = await thumbnail(ocId: ocId, fileId: fileId, etag: etag, pixels: pixels, store: store, client: client) }
    }

    /// Drops all in-memory decoded thumbnails (e.g. after a cache wipe).
    func clearMemory() {
        cache.removeAllObjects()
    }
}
