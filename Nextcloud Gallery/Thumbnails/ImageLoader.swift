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

    /// Live grid-prefetch tasks keyed by ``ThumbKey/id`` so a prefetch can be
    /// cancelled when its item leaves the prefetch window (scrolled past). Visible
    /// cells own their own load task in ``ThumbnailImageView``, not these.
    private var prefetchTasks: [String: Task<Void, Never>] = [:]

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
        client: NextcloudClient,
        priority: ThumbnailPriority = .visible
    ) async -> UIImage? {
        let key = ThumbKey(ocId: ocId, etag: etag, pixels: pixels)
        if let image = cache.object(forKey: key.id as NSString) { return image }

        guard let url = try? await store.load(
            ocId: ocId, fileId: fileId, etag: etag, pixels: pixels, client: client, priority: priority
        ) else { return nil }
        if Task.isCancelled { return nil }

        let maxPixels = pixels
        let output = await Task.detached(priority: priority == .visible ? .userInitiated : .utility) {
            ImageDownsampler.downsample(url: url, maxPixels: maxPixels)
        }.value
        guard let output, !Task.isCancelled else { return nil }

        let image = UIImage(cgImage: output.cgImage)
        cache.setObject(image, forKey: key.id as NSString)
        return image
    }

    /// Best-effort warm of a thumbnail ahead of display (collection-view prefetch),
    /// at `.prefetch` priority so it trails visible cells. Skips work already cached
    /// or already prefetching; cancel via ``cancelPrefetch(ocId:etag:pixels:)`` when
    /// the item scrolls out of the prefetch window.
    func prefetch(
        ocId: String, fileId: String, etag: String, pixels: Int,
        store: ThumbnailStore, client: NextcloudClient
    ) {
        let key = ThumbKey(ocId: ocId, etag: etag, pixels: pixels)
        if cache.object(forKey: key.id as NSString) != nil { return }
        if prefetchTasks[key.id] != nil { return }
        prefetchTasks[key.id] = Task { [weak self] in
            _ = await self?.thumbnail(ocId: ocId, fileId: fileId, etag: etag, pixels: pixels, store: store, client: client, priority: .prefetch)
            self?.prefetchTasks[key.id] = nil
        }
    }

    /// Cancels an in-flight grid prefetch for an item that left the prefetch window,
    /// so its download drops out of the gate and frees bandwidth for visible cells.
    func cancelPrefetch(ocId: String, etag: String, pixels: Int) {
        let key = ThumbKey(ocId: ocId, etag: etag, pixels: pixels)
        prefetchTasks.removeValue(forKey: key.id)?.cancel()
    }

    /// Drops all in-memory decoded thumbnails (e.g. after a cache wipe).
    func clearMemory() {
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        cache.removeAllObjects()
    }
}
