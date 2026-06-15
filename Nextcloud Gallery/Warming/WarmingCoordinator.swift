//
//  WarmingCoordinator.swift
//  Nextcloud Gallery
//
//  Drives the resumable, Wi-Fi-gated breadth-first crawl of the folder tree.
//

import Foundation
import Observation

/// Proactively crawls the folder structure so navigation is smooth. Two pools run
/// concurrently off one resumable frontier (persisted in `FolderState`):
///
/// - **Discovery** lists folders breadth-first (`FolderState.listState`), biased to
///   the folder the user is viewing, so structure is known before it's tapped.
/// - **Thumbnails** trail behind, prefetching each *listed* folder's cover tiles and
///   its photos' grid thumbnails (`FolderState.thumbnailsReady`). Kept off the
///   discovery path so listing — which unlocks navigation — never waits on image
///   downloads.
///
/// Both honor the same priority bias (``prioritize(currentFolderPath:)``) and are
/// cancellable at every `await`; partial progress is always persisted. Runs only
/// while conditions allow (foreground + Wi-Fi), decided by ``AppEnvironment``.
@Observable
@MainActor
final class WarmingCoordinator {
    enum State: Equatable {
        case idle
        case warming
        case paused
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let client: NextcloudClient
    @ObservationIgnored private let cacheStore: CacheStore
    @ObservationIgnored private let thumbnailStore: ThumbnailStore
    @ObservationIgnored private let monitor: NetworkMonitor
    @ObservationIgnored private let account: String
    @ObservationIgnored private var crawlTask: Task<Void, Never>?

    /// The subtree the crawl currently favors: the folder the user last navigated
    /// into. Both pools claim the shallowest eligible folder beneath this path
    /// before touching the global frontier, so the visible folder's descendants
    /// warm first. Re-pointed on every navigation; `nil` means an unbiased crawl.
    @ObservationIgnored private var priorityRoot: String?

    /// Live count of discovery workers still running. The thumbnail pool watches
    /// this so it keeps trailing while folders are still being discovered, then
    /// drains the backlog and exits once discovery is done.
    @ObservationIgnored private var activeDiscoveryWorkers = 0

    /// Concurrent folder-listing (discovery) workers.
    @ObservationIgnored private let discoveryWorkerCount = 5
    /// Concurrent thumbnail-prefetch workers; deliberately fewer so image downloads
    /// trail discovery and don't crowd out the photos the user is actively viewing.
    @ObservationIgnored private let thumbnailWorkerCount = 2
    /// Background queue so PROPFIND parsing never runs on the main thread.
    @ObservationIgnored private let networkQueue = DispatchQueue(label: "app.lyons.Nextcloud-Gallery.warming", qos: .utility)

    init(client: NextcloudClient, cacheStore: CacheStore, thumbnailStore: ThumbnailStore, monitor: NetworkMonitor) {
        self.client = client
        self.cacheStore = cacheStore
        self.thumbnailStore = thumbnailStore
        self.monitor = monitor
        self.account = client.credentials.account
    }

    /// Starts (or resumes) warming if conditions allow. Idempotent.
    func start() {
        guard crawlTask == nil, monitor.isWiFi else { return }
        state = .warming
        crawlTask = Task { await runCrawl() }
    }

    /// Pauses warming. Progress is preserved; `start()` resumes from the frontier
    /// (and keeps the current priority bias).
    func pause() {
        guard crawlTask != nil else { return }
        crawlTask?.cancel()
        crawlTask = nil
        state = .paused
    }

    /// When the user navigates into a folder, bias both crawls toward that folder's
    /// subtree so its descendants are listed and its images prefetched before
    /// anything else — making the next tap feel instant. Each navigation re-points
    /// the bias deeper (or to a sibling), so the just-entered folder always wins
    /// over the one a level up. Starts the crawl if it had gone idle; respects the
    /// Wi-Fi gate via `start()`.
    func prioritize(currentFolderPath: String) {
        guard !currentFolderPath.isEmpty else { return }
        priorityRoot = WebDAVPath.normalized(currentFolderPath)
        start()
    }

    private func runCrawl() async {
        // Recover any folders left mid-flight by a previous run, then seed the root.
        try? await cacheStore.resetClaimedToPending(account: account)
        if (try? await cacheStore.folderCount(account: account)) == 0 {
            try? await cacheStore.seedRoot(path: client.filesRootPath, account: account)
        }

        activeDiscoveryWorkers = discoveryWorkerCount
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<discoveryWorkerCount {
                group.addTask { await self.discoveryWorker() }
            }
            for _ in 0..<thumbnailWorkerCount {
                group.addTask { await self.thumbnailWorker() }
            }
        }

        crawlTask = nil
        if !Task.isCancelled {
            state = .idle
        }
    }

    /// Lists folders breadth-first, favoring the prioritized subtree, recording each
    /// listing and refreshing covers. Does *not* download thumbnails — that trails
    /// in ``thumbnailWorker()`` so discovery never blocks on image transfers.
    private func discoveryWorker() async {
        defer { activeDiscoveryWorkers -= 1 }
        while !Task.isCancelled {
            guard monitor.isWiFi else { return }
            // Read the live priority bias each claim, so workers converge on the
            // folder the user just navigated into within one listing.
            guard let folder = try? await cacheStore.claimNextPending(under: priorityRoot, account: account) else {
                return // discovery frontier empty
            }
            do {
                try Task.checkCancellation()
                let files = try await client.listFolder(at: folder.path, queue: networkQueue)
                try Task.checkCancellation()
                try await cacheStore.ingest(parentPath: folder.path, account: account, files: files)
                try? await cacheStore.recomputeCoverChain(
                    folderPath: folder.path, rootPath: client.filesRootPath, account: account
                )
            } catch is CancellationError {
                try? await cacheStore.markPending(path: folder.path, account: account)
                return
            } catch {
                // Transient failure: return it to the frontier and move on.
                try? await cacheStore.markPending(path: folder.path, account: account)
            }
        }
    }

    /// Trails discovery: prefetches thumbnails for already-listed folders, favoring
    /// the prioritized subtree. Keeps running (with a short back-off) while
    /// discovery is still finding folders, then drains the backlog and exits.
    private func thumbnailWorker() async {
        while !Task.isCancelled {
            guard monitor.isWiFi else { return }
            guard let folder = try? await cacheStore.claimNextNeedingThumbnails(under: priorityRoot, account: account) else {
                if activeDiscoveryWorkers == 0 { return } // discovery done, backlog drained
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            await prefetchThumbnails(for: folder.path)
        }
    }

    /// Caches a folder's images ahead of display: its (up to 4) 2x2 cover tiles
    /// first, then up to `gridThumbnailPrefetchLimit` of its own photos at grid
    /// size. Best-effort and Wi-Fi-gated; already-cached thumbnails are skipped
    /// cheaply by ``ThumbnailStore``.
    private func prefetchThumbnails(for folderPath: String) async {
        if let tiles = try? await cacheStore.coverTiles(folderPath: folderPath, account: account) {
            for tile in tiles {
                guard !Task.isCancelled, monitor.isWiFi else { return }
                await thumbnailStore.prefetch(
                    ocId: tile.ocId, fileId: tile.fileId, etag: tile.etag,
                    pixels: NextcloudConfig.coverTilePixels, client: client, queue: networkQueue
                )
            }
        }
        if let photos = try? await cacheStore.gridThumbnailTargets(
            folderPath: folderPath, account: account, limit: NextcloudConfig.gridThumbnailPrefetchLimit
        ) {
            for photo in photos {
                guard !Task.isCancelled, monitor.isWiFi else { return }
                await thumbnailStore.prefetch(
                    ocId: photo.ocId, fileId: photo.fileId, etag: photo.etag,
                    pixels: NextcloudConfig.gridThumbnailPixels, client: client, queue: networkQueue
                )
            }
        }
    }
}
