//
//  FlatGalleryViewController.swift
//  Nextcloud Gallery
//
//  All photos under a folder's subtree as one continuous, folder-agnostic grid.
//  Renders from the local cache (kept live by ``CacheChange``) while a recursive
//  server media-SEARCH fills in anything warming hasn't reached. Sort, zoom, and
//  aspect live on the ``BrowseTab`` so each tab remembers its own appearance.
//

import UIKit

final class FlatGalleryViewController: UIViewController {
    private let folderPath: String
    private let flatTitle: String
    private let account: String
    private let environment: AppEnvironment
    private let client: NextcloudClient
    private let browseTab: BrowseTab
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
    private var tabObservation: ObservationToken?

    // Last-applied appearance, to tell apart "sort changed → refetch" from
    // "zoom/aspect changed → just relayout/reconfigure".
    private var appliedSort: GallerySortOrder
    private var appliedZoom: GalleryGridZoom
    private var appliedAspectFill: Bool

    private var sortItem: UIBarButtonItem!
    private var aspectItem: UIBarButtonItem!
    private var zoomOutItem: UIBarButtonItem!
    private var zoomInItem: UIBarButtonItem!

    /// Tight, Photos-style inter-tile gap and outer margin.
    private let tileSpacing: CGFloat = 2

    private var thumbnailStore: ThumbnailStore { environment.thumbnailStore }
    private var cacheStore: CacheStore { environment.cacheStore }

    init(folderPath: String, title: String, account: String, environment: AppEnvironment, client: NextcloudClient, tab: BrowseTab, navigator: GalleryNavigator?) {
        self.folderPath = folderPath
        self.flatTitle = title
        self.account = account
        self.environment = environment
        self.client = client
        self.browseTab = tab
        self.navigator = navigator
        self.appliedSort = browseTab.sort
        self.appliedZoom = browseTab.zoom
        self.appliedAspectFill = browseTab.aspectFill
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
        navigationItem.title = flatTitle

        setUpCollectionView()
        setUpStatusView()
        configureDataSource()
        setUpToolbar()
        observeCacheChanges()
        observeTab()

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
            minItemWidth: metrics.minGridCellSize * browseTab.zoom.cellSizeMultiplier,
            spacing: tileSpacing, sectionInset: tileSpacing
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
            cell.configure(with: item, fill: self.browseTab.aspectFill, cornerRadius: self.browseTab.zoom.cornerRadius, store: self.thumbnailStore, client: self.client)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: photoCell, for: indexPath, item: item)
        }
    }

    private func setUpToolbar() {
        aspectItem = UIBarButtonItem(image: nil, style: .plain, target: self, action: #selector(toggleAspect))
        zoomOutItem = UIBarButtonItem(image: UIImage(systemName: "minus.magnifyingglass"), style: .plain, target: self, action: #selector(zoomOut))
        zoomInItem = UIBarButtonItem(image: UIImage(systemName: "plus.magnifyingglass"), style: .plain, target: self, action: #selector(zoomIn))
        sortItem = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: makeSortMenu())
        navigationItem.rightBarButtonItems = [zoomInItem, zoomOutItem, aspectItem, sortItem]
        updateToolbar()
    }

    private func makeSortMenu() -> UIMenu {
        let actions = GallerySortOrder.allCases.map { order in
            UIAction(title: order.label, image: UIImage(systemName: order.symbol), state: browseTab.sort == order ? .on : .off) { [weak self] _ in
                self?.browseTab.sort = order
            }
        }
        return UIMenu(title: "Sort", children: actions)
    }

    private func updateToolbar() {
        sortItem.menu = makeSortMenu()
        aspectItem.image = UIImage(systemName: browseTab.aspectFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        zoomOutItem.isEnabled = browseTab.zoom.canZoomOut
        zoomInItem.isEnabled = browseTab.zoom.canZoomIn
    }

    // MARK: - Observation

    private func observeTab() {
        tabObservation = observeChanges { [weak self] in
            guard let self else { return }
            // Touch the observed properties so changes re-fire this closure.
            let sort = self.browseTab.sort, zoom = self.browseTab.zoom, aspectFill = self.browseTab.aspectFill
            self.apply(sort: sort, zoom: zoom, aspectFill: aspectFill)
        }
    }

    private func apply(sort: GallerySortOrder, zoom: GalleryGridZoom, aspectFill: Bool) {
        let sortChanged = sort != appliedSort
        let zoomChanged = zoom != appliedZoom
        let aspectChanged = aspectFill != appliedAspectFill
        appliedSort = sort; appliedZoom = zoom; appliedAspectFill = aspectFill

        updateToolbar()
        if sortChanged { reloadFromCache() }
        guard zoomChanged || aspectChanged else { return }

        // One bouncy spring drives the whole change: the column/size change (zoom)
        // and each visible cell's photo-rect resize (fit/fill) animate together.
        // Off-screen cells pick up the new appearance from `configure` on dequeue.
        let newLayout = zoomChanged ? makeLayout() : nil
        let cells = collectionView.visibleCells.compactMap { $0 as? PhotoGridCell }
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3, options: [.allowUserInteraction]) {
            if let newLayout { self.collectionView.setCollectionViewLayout(newLayout, animated: false) }
            for cell in cells { cell.applyAppearance(fill: aspectFill, cornerRadius: zoom.cornerRadius) }
            self.collectionView.layoutIfNeeded()
        }
    }

    private func observeCacheChanges() {
        let base = WebDAVPath.normalized(folderPath)
        let prefix = base + "/"
        cacheObserver = NotificationCenter.default.addObserver(
            forName: CacheChange.didChange, object: nil, queue: .main
        ) { [weak self] note in
            let parents = CacheChange.parents(from: note)
            guard parents.contains(where: { $0 == base || $0.hasPrefix(prefix) }) else { return }
            MainActor.assumeIsolated { self?.reloadFromCache() }
        }
    }

    private func reloadFromCache() {
        let sort = appliedSort
        Task {
            let snapshots = (try? await cacheStore.flatItems(under: folderPath, account: account, sort: sort)) ?? []
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
            statusView.showEmpty(symbol: "photo.on.rectangle", title: "No Photos", message: "This folder has no photos.")
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
            let limit = NextcloudConfig.mediaSearchLimit
            let files = try await client.searchMedia(under: folderPath, limit: limit)
            try await cacheStore.reconcileSearchResults(under: folderPath, rootPath: client.filesRootPath, account: account, files: files, limit: limit)
            environment.warmingCoordinator?.prioritize(currentFolderPath: folderPath)
            reloadFromCache()
        } catch is CancellationError {
            // Navigated away; ignore.
        } catch {
            errorMessage = (error as? GalleryError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: - Actions

    @objc private func toggleAspect() { browseTab.aspectFill.toggle() }
    @objc private func zoomOut() { browseTab.zoom = browseTab.zoom.zoomedOut }
    @objc private func zoomIn() { browseTab.zoom = browseTab.zoom.zoomedIn }
    @objc private func pullToRefresh() { Task { await load() } }
}

// MARK: - Selection + prefetch

extension FlatGalleryViewController: UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let photos = items.map(PhotoItem.init(snapshot:))
        navigator?.openViewer(photos: photos, initialID: item.ocId, source: self)
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let item = dataSource.itemIdentifier(for: indexPath), item.hasPreview else { continue }
            ImageLoader.shared.prefetch(ocId: item.ocId, fileId: item.fileId, etag: item.etag, pixels: NextcloudConfig.gridThumbnailPixels, store: thumbnailStore, client: client)
        }
    }
}

// MARK: - Viewer transition source

extension FlatGalleryViewController: PhotoViewerTransitionSource {
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
