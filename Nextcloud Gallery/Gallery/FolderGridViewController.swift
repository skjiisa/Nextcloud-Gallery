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
    private weak var navigator: GalleryNavigator?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, GridItemSnapshot>!
    private let statusView = GridStatusView()
    private let refreshControl = UIRefreshControl()

    private var items: [GridItemSnapshot] = []
    private var isLoading = false
    private var errorMessage: String?
    private var didInitialLoad = false
    private var cacheObserver: NSObjectProtocol?

    private var thumbnailStore: ThumbnailStore { environment.thumbnailStore }
    private var cacheStore: CacheStore { environment.cacheStore }

    init(folderPath: String, title: String, account: String, environment: AppEnvironment, client: NextcloudClient, navigator: GalleryNavigator?) {
        self.folderPath = folderPath
        self.folderTitle = title
        self.account = account
        self.environment = environment
        self.client = client
        self.navigator = navigator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let cacheObserver { NotificationCenter.default.removeObserver(cacheObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = folderTitle
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Gallery", image: UIImage(systemName: "square.grid.3x3"),
            target: self, action: #selector(openFlatGallery)
        )

        setUpCollectionView()
        setUpStatusView()
        configureDataSource()
        observeCacheChanges()

        // Rebuild the layout when the size class changes (min cell size differs).
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.collectionView.setCollectionViewLayout(self.makeLayout(), animated: false)
        }

        reloadFromCache()
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
            minItemWidth: metrics.minGridCellSize, spacing: metrics.gridSpacing, sectionInset: metrics.contentPadding
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
            cell.configure(with: item, fill: true, cornerRadius: LayoutMetrics.tileCornerRadius, store: self.thumbnailStore, client: self.client)
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

    @objc private func openFlatGallery() {
        navigator?.openFlatGallery(FlatGalleryRoute(folderPath: folderPath, title: folderTitle, account: account))
    }

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
            navigator?.openFolder(FolderRoute(folderPath: item.fullPath, title: item.fileName, account: account))
        } else {
            let photos = items.filter { !$0.isDirectory }.map(PhotoItem.init(snapshot:))
            navigator?.openViewer(photos: photos, initialID: item.ocId)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath), item.isDirectory else { return nil }
        let route = FolderRoute(folderPath: item.fullPath, title: item.fileName, account: account)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let open = UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                self?.navigator?.openFolderInNewTab(route)
            }
            return UIMenu(children: [open])
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
}
