//
//  ThumbnailStore.swift
//  Nextcloud Gallery
//
//  Disk-backed thumbnail fetching with in-flight de-duplication.
//

import Foundation

/// Fetches thumbnails, caching them on disk and coalescing concurrent requests
/// for the same image so the grid, the cover resolver, and the prefetcher never
/// download the same thumbnail twice at once.
///
/// An `actor` because it touches disk + network and is called from background
/// pipelines as well as the main actor.
actor ThumbnailStore {
    private let location = ThumbnailCacheLocation()
    private var inFlight: [String: Task<URL, Error>] = [:]

    /// Returns a local file URL for the thumbnail, downloading it if needed.
    /// Foreground path: no network gating (see warming for the gated `prefetch`).
    func load(
        ocId: String,
        fileId: String,
        etag: String,
        pixels: Int,
        client: NextcloudClient,
        queue: DispatchQueue = .main
    ) async throws -> URL {
        let key = ThumbKey(ocId: ocId, etag: etag, pixels: pixels)
        let url = location.fileURL(for: key)

        if location.exists(url) { return url }
        if let existing = inFlight[key.id] { return try await existing.value }

        let task = Task<URL, Error> {
            let data = try await client.downloadPreview(fileId: fileId, etag: etag, pixels: pixels, queue: queue)
            try location.write(data, to: url)
            return url
        }
        inFlight[key.id] = task
        do {
            let result = try await task.value
            inFlight[key.id] = nil
            return result
        } catch {
            inFlight[key.id] = nil
            throw error
        }
    }

    /// Proactively caches a thumbnail (best-effort, result ignored). Callers gate
    /// this on Wi-Fi; the work runs on the provided background queue.
    func prefetch(ocId: String, fileId: String, etag: String, pixels: Int, client: NextcloudClient, queue: DispatchQueue) async {
        _ = try? await load(ocId: ocId, fileId: fileId, etag: etag, pixels: pixels, client: client, queue: queue)
    }

    /// Whether a thumbnail is already cached on disk (no network).
    func cachedURL(ocId: String, etag: String, pixels: Int) -> URL? {
        let url = location.fileURL(for: ThumbKey(ocId: ocId, etag: etag, pixels: pixels))
        return location.exists(url) ? url : nil
    }

    /// Evicts oldest thumbnails to keep the cache under a size budget.
    func reap(maxBytes: Int) {
        DiskCacheReaper.reap(directory: location.directory, maxBytes: maxBytes)
    }
}
