//
//  FolderGridViewController.swift
//  Nextcloud Gallery
//
//  A grid of the photos and folders in one folder, backed by the on-disk cache and
//  kept live by ``CacheChange``. Replaces the SwiftUI `FolderGridView` +
//  `@Query`-driven `LazyVGrid` with a `UICollectionView` + diffable data source:
//  one off-main fetch per change instead of per-cell query invalidation.
//

import UIKit

final class FolderGridViewController: UIViewController {
    private let folderPath: String
    private let folderTitle: String
    private let account: String
    private let environment: AppEnvironment
    private let client: NextcloudClient
    private let browseTab: BrowseTab
    private weak var navigator: GalleryNavigator?

    private var tabObservation: ObservationToken?
    private var appliedZoom: GalleryGridZoom

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, GridItemSnapshot>!
    private let statusView = GridStatusView()
    private let refreshControl = UIRefreshControl()

    private var items: [GridItemSnapshot] = []
    private var isLoading = false
    private var errorMessage: String?
    private var didInitialLoad = false
    private var cacheObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?

    /// Whether this folder contains any subfolder — drives the bottom bar's Gallery
    /// toggle (a folder with no subfolders is already shown flat, so the toggle is
    /// disabled). Fires `onContentChanged` when it may have changed.
    var hasSubfolders: Bool { items.contains { $0.isDirectory } }
    /// Called when `items` change (so the host can refresh bar state).
    var onContentChanged: (() -> Void)?

    private var thumbnailStore: ThumbnailStore { environment.thumbnailStore }
    private var cacheStore: CacheStore { environment.cacheStore }

    init(folderPath: String, title: String, account: String, environment: AppEnvironment, client: NextcloudClient, tab: BrowseTab, navigator: GalleryNavigator?) {
        self.folderPath = folderPath
        self.folderTitle = title
        self.account = account
        self.environment = environment
        self.client = client
        self.browseTab = tab
        self.appliedZoom = tab.zoom
        self.navigator = navigator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let cacheObserver { NotificationCenter.default.removeObserver(cacheObserver) }
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = folderTitle

        setUpCollectionView()
        setUpStatusView()
        configureDataSource()
        observeCacheChanges()
        observeLockChanges()
        observeZoom()

        // Rebuild the layout when the size class changes (min cell size differs).
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.collectionView.setCollectionViewLayout(self.makeLayout(), animated: false)
        }

        reloadFromCache()
    }

    /// Re-lay-out with a bouncy spring when the tab's zoom changes (the bottom bar's
    /// zoom buttons drive this folder grid as well as the flattened gallery).
    private func observeZoom() {
        tabObservation = observeChanges { [weak self] in
            guard let self else { return }
            let zoom = self.browseTab.zoom
            guard zoom != self.appliedZoom else { return }
            self.appliedZoom = zoom
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3, options: [.allowUserInteraction]) {
                self.collectionView.setCollectionViewLayout(self.makeLayout(), animated: false)
                self.collectionView.layoutIfNeeded()
            }
        }
    }

    /// Re-render a tile when its photo's zoom lock changes, so the locked crop tracks.
    private func observeLockChanges() {
        lockObserver = NotificationCenter.default.addObserver(
            forName: ZoomLockStore.didChange, object: nil, queue: .main
        ) { [weak self] note in
            let ocId = note.userInfo?["ocId"] as? String
            MainActor.assumeIsolated { self?.reconfigureItem(ocId: ocId) }
        }
    }

    private func reconfigureItem(ocId: String?) {
        var snapshot = dataSource.snapshot()
        // Only items still in the snapshot — reconfiguring a stale identifier asserts.
        let targets = snapshot.itemIdentifiers.filter { ocId == nil || $0.ocId == ocId }
        guard !targets.isEmpty else { return }
        snapshot.reconfigureItems(targets)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !didInitialLoad {
            didInitialLoad = true
            Task { await load() }
        }
    }

    // MARK: - Setup

    private func makeLayout() -> UICollectionViewLayout {
        let metrics = LayoutMetrics(traits: traitCollection)
        return GalleryGridLayout.make(
            minItemWidth: metrics.minGridCellSize * browseTab.zoom.cellSizeMultiplier,
            spacing: metrics.gridSpacing, sectionInset: metrics.contentPadding
        )
    }

    private func setUpCollectionView() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        collectionView.refreshControl = refreshControl
        view.addSubview(collectionView)
    }

    private func setUpStatusView() {
        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.onRetry = { [weak self] in Task { await self?.load() } }
        view.addSubview(statusView)
        NSLayoutConstraint.activate([
            statusView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            statusView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            statusView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureDataSource() {
        let photoCell = UICollectionView.CellRegistration<PhotoGridCell, GridItemSnapshot> { [weak self] cell, _, item in
            guard let self else { return }
            cell.configure(with: item, fill: true, cornerRadius: LayoutMetrics.tileCornerRadius,
                           lock: self.environment.zoomLockStore.lock(for: item.ocId), store: self.thumbnailStore, client: self.client)
        }
        let folderCell = UICollectionView.CellRegistration<FolderGridCell, GridItemSnapshot> { [weak self] cell, _, item in
            guard let self else { return }
            cell.configure(with: item, store: self.thumbnailStore, client: self.client)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            if item.isDirectory {
                return collectionView.dequeueConfiguredReusableCell(using: folderCell, for: indexPath, item: item)
            } else {
                return collectionView.dequeueConfiguredReusableCell(using: photoCell, for: indexPath, item: item)
            }
        }
    }

    // MARK: - Data

    private func observeCacheChanges() {
        let target = WebDAVPath.normalized(folderPath)
        cacheObserver = NotificationCenter.default.addObserver(
            forName: CacheChange.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard CacheChange.parents(from: note).contains(target) else { return }
            MainActor.assumeIsolated { self?.reloadFromCache() }
        }
    }

    private func reloadFromCache() {
        Task {
            let snapshots = (try? await cacheStore.folderItems(parentPath: folderPath, account: account)) ?? []
            self.items = snapshots
            applySnapshot()
            updateStatus()
            onContentChanged?()
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, GridItemSnapshot>()
        snapshot.appendSections([0])
        snapshot.appendItems(items, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func updateStatus() {
        if isLoading && items.isEmpty {
            statusView.showLoading()
        } else if let errorMessage, items.isEmpty {
            statusView.showError(symbol: "exclamationmark.triangle", title: "Couldn't load", message: errorMessage)
        } else if items.isEmpty {
            statusView.showEmpty(symbol: "photo.on.rectangle", title: "No Photos", message: "This folder is empty.")
        } else {
            statusView.hide()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        updateStatus()
        defer {
            isLoading = false
            refreshControl.endRefreshing()
            updateStatus()
        }
        do {
            let files = try await client.listFolder(at: folderPath)
            try await cacheStore.ingest(parentPath: folderPath, account: account, files: files)
            try? await cacheStore.recomputeCoverChain(folderPath: folderPath, rootPath: client.filesRootPath, account: account)
            environment.warmingCoordinator?.prioritize(currentFolderPath: folderPath)
            reloadFromCache()
        } catch is CancellationError {
            // Navigated away; ignore.
        } catch {
            errorMessage = (error as? GalleryError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: - Actions

    @objc private func pullToRefresh() {
        Task { await load() }
    }
}

// MARK: - Selection, context menus, prefetch

extension FolderGridViewController: UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        if item.isDirectory {
            navigator?.openFolder(FolderRoute(folderPath: item.fullPath, title: item.fileName, account: account), mode: nil)
        } else {
            let photos = items.filter { !$0.isDirectory }.map(PhotoItem.init(snapshot:))
            navigator?.openViewer(photos: photos, initialID: item.ocId, source: self)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath), item.isDirectory else { return nil }
        let route = FolderRoute(folderPath: item.fullPath, title: item.fileName, account: account)
        let path = item.fullPath
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let open = UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                self?.navigator?.openFolderInNewTab(route)
            }
            // Fetch the folder's current favorite state so the action reads correctly.
            let favorite = UIDeferredMenuElement.uncached { [weak self] completion in
                Task { @MainActor in
                    let isFavorite = (try? await self?.client.fileMetadata(serverPath: path))?.isFavorite ?? false
                    let action = UIAction(
                        title: isFavorite ? "Remove from Favorites" : "Favorite",
                        image: UIImage(systemName: isFavorite ? "star.slash" : "star")
                    ) { _ in self?.setFavorite(path: path, to: !isFavorite) }
                    completion([action])
                }
            }
            return UIMenu(children: [favorite, open])
        }
    }

    /// Toggles a folder's favorite state (no grid badge yet — it surfaces in Home's
    /// Favorites on next load). A haptic confirms the result.
    private func setFavorite(path: String, to favorite: Bool) {
        Task {
            do {
                try await client.setFavorite(serverPath: path, favorite: favorite)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let item = dataSource.itemIdentifier(for: indexPath) else { continue }
            if item.isDirectory {
                for tile in item.coverTiles {
                    ImageLoader.shared.prefetch(ocId: tile.ocId, fileId: tile.fileId, etag: tile.etag, pixels: NextcloudConfig.coverTilePixels, store: thumbnailStore, client: client)
                }
            } else if item.hasPreview {
                ImageLoader.shared.prefetch(ocId: item.ocId, fileId: item.fileId, etag: item.etag, pixels: NextcloudConfig.gridThumbnailPixels, store: thumbnailStore, client: client)
            }
        }
    }

    /// The item scrolled out of the prefetch window before it finished loading —
    /// cancel it so its download yields the gate to on-screen cells.
    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let item = dataSource.itemIdentifier(for: indexPath) else { continue }
            if item.isDirectory {
                for tile in item.coverTiles {
                    ImageLoader.shared.cancelPrefetch(ocId: tile.ocId, etag: tile.etag, pixels: NextcloudConfig.coverTilePixels)
                }
            } else if item.hasPreview {
                ImageLoader.shared.cancelPrefetch(ocId: item.ocId, etag: item.etag, pixels: NextcloudConfig.gridThumbnailPixels)
            }
        }
    }
}

// MARK: - Viewer transition source

extension FolderGridViewController: PhotoViewerTransitionSource {
    func viewerSourceFrame(forPhotoID id: String, in space: UICoordinateSpace) -> CGRect? {
        GridTransitionSource.sourceFrame(forPhotoID: id, in: space, collectionView: collectionView, items: items)
    }

    func viewerSourceImage(forPhotoID id: String) -> UIImage? {
        GridTransitionSource.sourceImage(forPhotoID: id, collectionView: collectionView, items: items)
    }

    func setViewerSourceHidden(_ hidden: Bool, forPhotoID id: String) {
        GridTransitionSource.setHidden(hidden, forPhotoID: id, collectionView: collectionView, items: items)
    }
}
