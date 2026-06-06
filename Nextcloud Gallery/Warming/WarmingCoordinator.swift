//
//  WarmingCoordinator.swift
//  Nextcloud Gallery
//
//  Drives the resumable, Wi-Fi-gated breadth-first crawl of the folder tree.
//

import Foundation
import Observation

/// Proactively crawls the full folder structure so navigation is smooth. The
/// frontier lives in SwiftData (`FolderState.listState`), so the crawl is
/// inherently resumable: on every start it just picks up the pending folders.
///
/// The crawl is breadth-first, and biased toward the folder the user is currently
/// viewing (``prioritize(currentFolderPath:)``): all workers list the visible
/// folder's subtree first, so tapping a subfolder usually finds it already cached,
/// then spill back out to the rest of the tree once that subtree is warm.
///
/// Cancellable at every `await`; partial progress is always persisted. Runs only
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
    /// into. Workers claim the shallowest pending folder beneath this path before
    /// touching the global frontier, so the visible folder's descendants warm
    /// first. Re-pointed on every navigation; `nil` means an unbiased global crawl.
    @ObservationIgnored private var priorityRoot: String?

    /// Number of concurrent folder-listing workers.
    @ObservationIgnored private let workerCount = 5
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

    /// When the user navigates into a folder, bias the crawl toward that folder's
    /// subtree so its descendants are listed before anything else — making the next
    /// tap feel instant. Each navigation re-points the bias deeper (or to a
    /// sibling), so the just-entered folder always wins over the one a level up.
    /// Starts the crawl if it had gone idle; respects the Wi-Fi gate via `start()`.
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

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask { await self.worker() }
            }
        }

        crawlTask = nil
        if !Task.isCancelled {
            state = .idle
        }
    }

    private func worker() async {
        while !Task.isCancelled {
            guard monitor.isWiFi else { return }
            // Read the live priority bias each claim, so workers converge on the
            // folder the user just navigated into within one listing.
            guard let folder = try? await cacheStore.claimNextPending(under: priorityRoot, account: account) else {
                return // frontier empty
            }
            do {
                try Task.checkCancellation()
                let files = try await client.listFolder(at: folder.path, queue: networkQueue)
                try Task.checkCancellation()
                try await cacheStore.ingest(parentPath: folder.path, account: account, files: files)
                try? await cacheStore.recomputeCoverChain(
                    folderPath: folder.path, rootPath: client.filesRootPath, account: account
                )
                await prefetchCoverTiles(for: folder.path)
            } catch is CancellationError {
                try? await cacheStore.markPending(path: folder.path, account: account)
                return
            } catch {
                // Transient failure: return it to the frontier and move on.
                try? await cacheStore.markPending(path: folder.path, account: account)
            }
        }
    }

    /// Proactively caches the (up to 4) cover thumbnails for a folder so its 2x2
    /// composite is ready before the parent grid is ever shown.
    private func prefetchCoverTiles(for folderPath: String) async {
        guard let tiles = try? await cacheStore.coverTiles(folderPath: folderPath, account: account) else { return }
        for tile in tiles {
            guard !Task.isCancelled, monitor.isWiFi else { return }
            await thumbnailStore.prefetch(
                ocId: tile.ocId, fileId: tile.fileId, etag: tile.etag,
                pixels: NextcloudConfig.coverTilePixels, client: client, queue: networkQueue
            )
        }
    }
}
