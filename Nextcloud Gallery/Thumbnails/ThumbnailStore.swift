//
//  ThumbnailStore.swift
//  Nextcloud Gallery
//
//  Disk-backed thumbnail fetching with in-flight de-duplication and priority gating.
//

import Foundation

/// Fetches thumbnails, caching them on disk and coalescing concurrent requests for
/// the same image so the grid, the cover resolver, and the prefetcher never download
/// the same thumbnail twice at once. Downloads pass through a
/// ``ThumbnailDownloadGate`` so visible cells outrank prefetch/warming work and a
/// request whose requesters all cancel (scrolled off-screen) drops out before it
/// reaches the network.
///
/// An `actor` because it touches disk + network and is called from background
/// pipelines as well as the main actor.
actor ThumbnailStore {
    private let location = ThumbnailCacheLocation()
    private let gate = ThumbnailDownloadGate(limit: NextcloudConfig.maxConcurrentThumbnailDownloads)

    /// A coalesced download and how many callers are still awaiting it. When the last
    /// caller cancels, the download is cancelled too (so a queued one never starts).
    private struct InFlight {
        let task: Task<URL, Error>
        var requesters: Int
    }
    private var inFlight: [String: InFlight] = [:]

    /// Returns a local file URL for the thumbnail, downloading it if needed.
    /// Foreground path: no network gating (see warming for the gated `prefetch`).
    func load(
        ocId: String,
        fileId: String,
        etag: String,
        pixels: Int,
        client: NextcloudClient,
        priority: ThumbnailPriority = .visible,
        queue: DispatchQueue = .main
    ) async throws -> URL {
        let key = ThumbKey(ocId: ocId, etag: etag, pixels: pixels)
        let url = location.fileURL(for: key)
        if location.exists(url) { return url }

        let task = joinOrStartDownload(key: key, url: url, fileId: fileId, etag: etag, pixels: pixels, client: client, priority: priority, queue: queue)
        // Awaiting the shared task isn't itself cancellable, so on cancellation drop
        // this requester explicitly; the download is cancelled once none remain.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.dropRequester(key.id) }
        }
    }

    private func joinOrStartDownload(
        key: ThumbKey, url: URL, fileId: String, etag: String, pixels: Int,
        client: NextcloudClient, priority: ThumbnailPriority, queue: DispatchQueue
    ) -> Task<URL, Error> {
        if var entry = inFlight[key.id] {
            entry.requesters += 1
            inFlight[key.id] = entry
            return entry.task
        }
        let task = Task<URL, Error> {
            try await self.runDownload(key: key, url: url, fileId: fileId, etag: etag, pixels: pixels, client: client, high: priority == .visible, queue: queue)
        }
        inFlight[key.id] = InFlight(task: task, requesters: 1)
        return task
    }

    private func runDownload(
        key: ThumbKey, url: URL, fileId: String, etag: String, pixels: Int,
        client: NextcloudClient, high: Bool, queue: DispatchQueue
    ) async throws -> URL {
        do {
            try await gate.acquire(high: high)
        } catch {
            finish(key.id)            // cancelled while queued — never hit the network
            throw error
        }
        do {
            let data = try await client.downloadPreview(fileId: fileId, etag: etag, pixels: pixels, queue: queue)
            try location.write(data, to: url)
            await gate.release()
            finish(key.id)
            return url
        } catch {
            await gate.release()
            finish(key.id)
            throw error
        }
    }

    private func finish(_ keyID: String) {
        inFlight[keyID] = nil
    }

    private func dropRequester(_ keyID: String) {
        guard var entry = inFlight[keyID] else { return }
        entry.requesters -= 1
        if entry.requesters <= 0 {
            entry.task.cancel()
            inFlight[keyID] = nil
        } else {
            inFlight[keyID] = entry
        }
    }

    /// Proactively caches a thumbnail (best-effort, result ignored). Callers gate
    /// this on Wi-Fi; the work runs on the provided background queue at low priority
    /// so it trails the visible grid.
    func prefetch(ocId: String, fileId: String, etag: String, pixels: Int, client: NextcloudClient, queue: DispatchQueue) async {
        _ = try? await load(ocId: ocId, fileId: fileId, etag: etag, pixels: pixels, client: client, priority: .prefetch, queue: queue)
    }

    /// Whether a thumbnail is already cached on disk (no network).
    func cachedURL(ocId: String, etag: String, pixels: Int) -> URL? {
        let url = location.fileURL(for: ThumbKey(ocId: ocId, etag: etag, pixels: pixels))
        return location.exists(url) ? url : nil
    }

    /// Deletes one cached thumbnail from disk — e.g. a zoom lock's higher-res copy when
    /// the lock is cleared. Cancels an in-flight download for it first so it can't be
    /// re-written after deletion.
    func remove(ocId: String, etag: String, pixels: Int) {
        let key = ThumbKey(ocId: ocId, etag: etag, pixels: pixels)
        inFlight.removeValue(forKey: key.id)?.task.cancel()
        location.remove(location.fileURL(for: key))
    }

    /// Evicts oldest thumbnails to keep the cache under a size budget.
    func reap(maxBytes: Int) {
        DiskCacheReaper.reap(directory: location.directory, maxBytes: maxBytes)
    }

    /// Deletes every cached thumbnail, cancelling any in-flight downloads so they
    /// can't re-create files behind the wipe.
    func clear() {
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
        DiskCacheReaper.clear(directory: location.directory)
    }
}
