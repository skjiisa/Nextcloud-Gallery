//
//  CacheStore.swift
//  Nextcloud Gallery
//
//  The single owner of all SwiftData writes, isolated off the main actor.
//

import Foundation
import SwiftData
import NextcloudKit

/// Background actor that owns a private `ModelContext`. Every write to the cache
/// goes through here so heavy crawl/ingest work never runs on the main thread.
/// The SwiftUI grid reads the same container via `@Query` on the main context,
/// which auto-merges these saves.
@ModelActor
actor CacheStore {
    /// Upserts the children of a folder from a fresh listing, prunes deleted
    /// entries, ensures a ``FolderState`` exists for each child folder, and marks
    /// the parent folder as listed.
    func ingest(parentPath: String, account: String, files: [NKFile]) throws {
        let parent = WebDAVPath.normalized(parentPath)

        let existing = try children(parentPath: parent, account: account)
        var byOcId: [String: CachedItem] = [:]
        for item in existing { byOcId[item.ocId] = item }

        let parentDepth = try folderState(path: parent, account: account)?.depth ?? 0

        var seen = Set<String>()
        for file in files {
            let fullPath = WebDAVPath.normalized(file.serverUrl + "/" + file.fileName)
            seen.insert(file.ocId)

            if let item = byOcId[file.ocId] {
                item.apply(file: file, parentPath: parent, fullPath: fullPath, account: account)
            } else {
                modelContext.insert(CachedItem(file: file, parentPath: parent, fullPath: fullPath, account: account))
            }

            if file.directory, try folderState(path: fullPath, account: account) == nil {
                modelContext.insert(FolderState(
                    folderPath: fullPath,
                    account: account,
                    etag: file.etag,
                    listState: .pending,
                    depth: parentDepth + 1
                ))
            }
        }

        // Prune items that disappeared from the folder.
        for item in existing where !seen.contains(item.ocId) {
            if item.isDirectory, let state = try folderState(path: item.fullPath, account: account) {
                modelContext.delete(state)
            }
            modelContext.delete(item)
        }

        // Mark the parent folder listed (creating its state if this is the root).
        if let parentState = try folderState(path: parent, account: account) {
            parentState.listState = .listed
            parentState.lastListed = Date()
        } else {
            let state = FolderState(folderPath: parent, account: account, listState: .listed, depth: parentDepth, lastListed: Date())
            modelContext.insert(state)
        }

        try modelContext.save()
    }

    /// Deletes the entire cached folder tree and crawl state for every account.
    /// Deletes row-by-row (rather than a batch `delete(model:)`) so the change
    /// notifications merge into the main context and the live grid empties at once.
    func clearAll() throws {
        for item in try modelContext.fetch(FetchDescriptor<CachedItem>()) {
            modelContext.delete(item)
        }
        for state in try modelContext.fetch(FetchDescriptor<FolderState>()) {
            modelContext.delete(state)
        }
        try modelContext.save()
    }

    /// Whether the given folder has ever been successfully listed.
    func isListed(path: String, account: String) throws -> Bool {
        try folderState(path: WebDAVPath.normalized(path), account: account)?.listState == .listed
    }

    // MARK: - Warming crawl

    /// Seeds the root folder as pending if the store is empty for this account.
    func seedRoot(path: String, account: String) throws {
        let root = WebDAVPath.normalized(path)
        guard try folderState(path: root, account: account) == nil else { return }
        modelContext.insert(FolderState(folderPath: root, account: account, listState: .pending, depth: 0))
        try modelContext.save()
    }

    /// Resets any folders left `.claimed` (e.g. by a crash) back to `.pending`.
    func resetClaimedToPending(account: String) throws {
        let claimedRaw = ListState.claimed.rawValue
        let descriptor = FetchDescriptor<FolderState>(
            predicate: #Predicate { $0.account == account && $0.listStateRaw == claimedRaw }
        )
        let claimed = try modelContext.fetch(descriptor)
        guard !claimed.isEmpty else { return }
        for folder in claimed { folder.listState = .pending }
        try modelContext.save()
    }

    /// Atomically claims the next folder to crawl, biasing toward `root` — the
    /// folder the user is currently viewing. The shallowest pending folder *under*
    /// `root` (breadth-first within that subtree) is claimed first; only once that
    /// subtree is fully listed does it fall back to the globally shallowest pending
    /// folder. Pass `nil` for an unbiased global breadth-first claim.
    ///
    /// Serialized by the actor, so two workers can never claim the same folder.
    func claimNextPending(under root: String?, account: String) throws -> FolderDTO? {
        let pendingRaw = ListState.pending.rawValue

        // First choice: the shallowest pending folder within the prioritized
        // subtree (the folder itself, or anything beneath its `path + "/"`).
        if let root {
            let base = WebDAVPath.normalized(root)
            let prefix = base + "/"
            var descriptor = FetchDescriptor<FolderState>(
                predicate: #Predicate {
                    $0.account == account && $0.listStateRaw == pendingRaw
                        && ($0.folderPath == base || $0.folderPath.starts(with: prefix))
                },
                sortBy: [SortDescriptor(\.depth), SortDescriptor(\.folderPath)]
            )
            descriptor.fetchLimit = 1
            if let folder = try modelContext.fetch(descriptor).first {
                return try claim(folder)
            }
        }

        // Fallback: the globally shallowest pending folder (keeps the rest of the
        // tree warming once the prioritized subtree is exhausted).
        var descriptor = FetchDescriptor<FolderState>(
            predicate: #Predicate { $0.account == account && $0.listStateRaw == pendingRaw },
            sortBy: [SortDescriptor(\.depth), SortDescriptor(\.folderPath)]
        )
        descriptor.fetchLimit = 1
        guard let folder = try modelContext.fetch(descriptor).first else { return nil }
        return try claim(folder)
    }

    /// Marks a fetched folder as claimed and returns its Sendable snapshot.
    private func claim(_ folder: FolderState) throws -> FolderDTO {
        folder.listState = .claimed
        try modelContext.save()
        return FolderDTO(path: folder.folderPath, depth: folder.depth, etag: folder.etag)
    }

    // MARK: - Trailing thumbnail crawl

    /// Atomically claims the next *listed* folder whose thumbnails haven't been
    /// prefetched yet, biasing toward `root` (the folder the user is viewing)
    /// before the global frontier — so the trailing thumbnail crawler warms the
    /// visible subtree's images first. Only folders discovery has already listed
    /// are eligible, so this naturally hangs behind the structural crawl.
    ///
    /// Marks the folder ready on claim, both to serialize the small thumbnail pool
    /// (two workers never pick the same folder) and because the work is best-effort:
    /// anything missed simply loads on demand. Returns nil when nothing needs it.
    func claimNextNeedingThumbnails(under root: String?, account: String) throws -> FolderDTO? {
        let listedRaw = ListState.listed.rawValue

        if let root {
            let base = WebDAVPath.normalized(root)
            let prefix = base + "/"
            var descriptor = FetchDescriptor<FolderState>(
                predicate: #Predicate {
                    $0.account == account && $0.listStateRaw == listedRaw && !$0.thumbnailsReady
                        && ($0.folderPath == base || $0.folderPath.starts(with: prefix))
                },
                sortBy: [SortDescriptor(\.depth), SortDescriptor(\.folderPath)]
            )
            descriptor.fetchLimit = 1
            if let folder = try modelContext.fetch(descriptor).first {
                return try markThumbnailsClaimed(folder)
            }
        }

        var descriptor = FetchDescriptor<FolderState>(
            predicate: #Predicate {
                $0.account == account && $0.listStateRaw == listedRaw && !$0.thumbnailsReady
            },
            sortBy: [SortDescriptor(\.depth), SortDescriptor(\.folderPath)]
        )
        descriptor.fetchLimit = 1
        guard let folder = try modelContext.fetch(descriptor).first else { return nil }
        return try markThumbnailsClaimed(folder)
    }

    private func markThumbnailsClaimed(_ folder: FolderState) throws -> FolderDTO {
        folder.thumbnailsReady = true
        try modelContext.save()
        return FolderDTO(path: folder.folderPath, depth: folder.depth, etag: folder.etag)
    }

    /// Up to `limit` of a folder's own photos (non-folder items with a server
    /// preview), in the order the grid shows them, as targets for thumbnail
    /// prefetch. Mirrors ``FolderGridView``'s sort so the first cells warm first.
    func gridThumbnailTargets(folderPath: String, account: String, limit: Int) throws -> [CoverTile] {
        let parent = WebDAVPath.normalized(folderPath)
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate {
                $0.parentPath == parent && $0.account == account && !$0.isDirectory && $0.hasPreview
            },
            sortBy: [SortDescriptor(\.kindRank), SortDescriptor(\.nameKey)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
            .map { CoverTile(ocId: $0.ocId, fileId: $0.fileId, etag: $0.etag) }
    }

    /// Returns a claimed/failed folder to the pending frontier.
    func markPending(path: String, account: String) throws {
        guard let folder = try folderState(path: WebDAVPath.normalized(path), account: account) else { return }
        folder.listState = .pending
        try modelContext.save()
    }

    /// Total number of known folders for an account (0 means nothing crawled yet).
    func folderCount(account: String) throws -> Int {
        let descriptor = FetchDescriptor<FolderState>(predicate: #Predicate { $0.account == account })
        return try modelContext.fetchCount(descriptor)
    }

    /// Number of folders still awaiting a crawl.
    func pendingCount(account: String) throws -> Int {
        let pendingRaw = ListState.pending.rawValue
        let descriptor = FetchDescriptor<FolderState>(
            predicate: #Predicate { $0.account == account && $0.listStateRaw == pendingRaw }
        )
        return try modelContext.fetchCount(descriptor)
    }

    /// The current cover tiles for a folder (for proactive thumbnail prefetch).
    func coverTiles(folderPath: String, account: String) throws -> [CoverTile] {
        try folderState(path: WebDAVPath.normalized(folderPath), account: account)?.coverTiles ?? []
    }

    /// Copies each folder's memoized cover tiles from its ``FolderState`` onto the
    /// matching ``CachedItem`` directory row. Idempotent (writes only on a diff),
    /// so it's safe to run at every launch; needed once after introducing the
    /// denormalized ``CachedItem/coverTiles`` so already-crawled folders show their
    /// covers without waiting to be re-crawled.
    func backfillFolderItemCovers(account: String) throws {
        let states = try modelContext.fetch(
            FetchDescriptor<FolderState>(predicate: #Predicate { $0.account == account })
        )
        var changed = false
        for state in states where !state.coverTiles.isEmpty {
            guard let item = try cachedFolderItem(fullPath: state.folderPath, account: account),
                  item.coverTiles != state.coverTiles else { continue }
            item.coverTiles = state.coverTiles
            changed = true
        }
        if changed { try modelContext.save() }
    }

    // MARK: - 2x2 covers

    /// Recomputes the cover for a folder and walks up to the root, so a newly
    /// crawled descendant propagates into its ancestors' covers. Saves once.
    func recomputeCoverChain(folderPath: String, rootPath: String, account: String) throws {
        let root = WebDAVPath.normalized(rootPath)
        var current = WebDAVPath.normalized(folderPath)
        var changed = false
        while true {
            // If a level's cover is unchanged, every ancestor's input from this
            // subtree is unchanged too, so the propagation can stop here. (A change
            // only reaches an ancestor through this folder's representative tile.)
            guard try recomputeCover(folderPath: current, account: account) else { break }
            changed = true
            if current == root { break }
            guard let parent = parentPath(of: current, notAbove: root) else { break }
            current = parent
        }
        if changed { try modelContext.save() }
    }

    /// Picks up to 4 representative tiles for a folder, preferring spread across
    /// distinct subfolders, then the folder's own photos, then deeper photos.
    /// Returns whether anything changed (so callers can skip redundant saves and
    /// avoid UI churn). Does not save.
    @discardableResult
    private func recomputeCover(folderPath: String, account: String) throws -> Bool {
        guard let state = try folderState(path: folderPath, account: account) else { return false }
        let kids = try children(parentPath: folderPath, account: account)

        let directImages = kids
            .filter { !$0.isDirectory && $0.classFile == "image" && $0.hasPreview }
            .sorted(by: Self.stableOrder)
        let childDirs = kids
            .filter { $0.isDirectory }
            .sorted { $0.nameKey < $1.nameKey }

        var picks: [CoverTile] = []
        var used = Set<String>()

        // Pass 1: one representative from each distinct subfolder (variety first).
        for dir in childDirs where picks.count < 4 {
            if let rep = try representativeTile(folderPath: dir.fullPath, account: account), used.insert(rep.ocId).inserted {
                picks.append(rep)
            }
        }
        // Pass 2: the folder's own direct photos.
        for image in directImages where picks.count < 4 {
            if used.insert(image.ocId).inserted {
                picks.append(CoverTile(ocId: image.ocId, fileId: image.fileId, etag: image.etag))
            }
        }
        // Pass 3: go deeper, round-robin across subfolders' representative tiles.
        if picks.count < 4 {
            let perDir = childDirs.map { (try? folderState(path: $0.fullPath, account: account))?.coverTiles ?? [] }
            var depthIndex = 1
            while picks.count < 4 && depthIndex <= 4 {
                var addedThisRound = false
                for tiles in perDir where picks.count < 4 {
                    guard depthIndex < tiles.count else { continue }
                    let tile = tiles[depthIndex]
                    if used.insert(tile.ocId).inserted {
                        picks.append(tile)
                        addedThisRound = true
                    }
                }
                if !addedThisRound { break }
                depthIndex += 1
            }
        }

        let resolved = picks.count == 4 || state.listState == .listed
        let tilesChanged = state.coverTiles != picks
        let resolvedChanged = state.coverResolved != resolved
        guard tilesChanged || resolvedChanged else { return false }

        if tilesChanged { state.coverTiles = picks }
        if resolvedChanged { state.coverResolved = resolved }
        // Mirror onto the folder's cached row only when the tiles actually moved —
        // that row is observed by the visible grid's `@Query`, so an unchanged
        // write here invalidates every cell on screen. (The root has a state but
        // no item, hence the optional lookup.)
        if tilesChanged,
           let folderItem = try cachedFolderItem(fullPath: folderPath, account: account),
           folderItem.coverTiles != picks {
            folderItem.coverTiles = picks
        }
        return true
    }

    /// The single best tile to represent a folder: its memoized first cover tile,
    /// else its first direct photo. Deliberately does NOT recurse into subfolders:
    /// that descent re-fetched whole subtrees on every recompute and was the
    /// dominant source of main-thread hangs. A subfolder-only folder's tile instead
    /// arrives once a descendant is crawled and its cover propagates up the chain.
    private func representativeTile(folderPath: String, account: String) throws -> CoverTile? {
        if let first = try folderState(path: folderPath, account: account)?.coverTiles.first {
            return first
        }
        let kids = try children(parentPath: folderPath, account: account)
        if let image = kids
            .filter({ !$0.isDirectory && $0.classFile == "image" && $0.hasPreview })
            .sorted(by: Self.stableOrder).first {
            return CoverTile(ocId: image.ocId, fileId: image.fileId, etag: image.etag)
        }
        return nil
    }

    /// Deterministic order (newest first, then name) so covers are stable.
    private static func stableOrder(_ lhs: CachedItem, _ rhs: CachedItem) -> Bool {
        lhs.date != rhs.date ? lhs.date > rhs.date : lhs.nameKey < rhs.nameKey
    }

    /// The parent folder path, or nil at/above `root`.
    private func parentPath(of path: String, notAbove root: String) -> String? {
        guard path != root, let slash = path.range(of: "/", options: .backwards) else { return nil }
        let parent = String(path[path.startIndex..<slash.lowerBound])
        return parent.count >= root.count ? parent : nil
    }

    // MARK: - Private fetch helpers

    private func children(parentPath: String, account: String) throws -> [CachedItem] {
        let descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate { $0.parentPath == parentPath && $0.account == account }
        )
        return try modelContext.fetch(descriptor)
    }

    private func folderState(path: String, account: String) throws -> FolderState? {
        let descriptor = FetchDescriptor<FolderState>(
            predicate: #Predicate { $0.folderPath == path && $0.account == account }
        )
        return try modelContext.fetch(descriptor).first
    }

    /// The cached directory row for a folder (keyed by its own `fullPath`). The
    /// root folder has a ``FolderState`` but is no folder's child, so it has no
    /// such row and this returns nil there.
    private func cachedFolderItem(fullPath: String, account: String) throws -> CachedItem? {
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate { $0.fullPath == fullPath && $0.account == account && $0.isDirectory }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
