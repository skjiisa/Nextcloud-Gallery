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

    /// Every photo under the subtree, straight from the cache. `items` is this set
    /// after the active ``GalleryFilter`` is applied — it's what the grid, viewer,
    /// and transition source all see.
    private var allItems: [GridItemSnapshot] = []
    private var items: [GridItemSnapshot] = []
    private var isLoading = false
    private var errorMessage: String?
    private var didInitialLoad = false
    private var cacheObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?
    private var tabObservation: ObservationToken?

    // The account's favorited ocIds, fetched lazily the first time the favorites
    // filter is on (favorites aren't cached locally). `nil` means "not loaded yet".
    private var favoriteOcIds: Set<String>?
    private var isLoadingFavorites = false
    private var favoritesError: String?

    // Last-applied appearance, to tell apart "sort/filter changed → refetch/refilter"
    // from "zoom/aspect changed → just relayout/reconfigure".
    private var appliedSort: GallerySortOrder
    private var appliedZoom: GalleryGridZoom
    private var appliedAspectFill: Bool
    private var appliedFilter: GalleryFilter

    private var sortItem: UIBarButtonItem!
    private var aspectItem: UIBarButtonItem!
    private var filterItem: UIBarButtonItem!

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
        self.appliedFilter = browseTab.filter
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
        navigationItem.title = flatTitle

        setUpCollectionView()
        setUpStatusView()
        configureDataSource()
        setUpToolbar()
        observeCacheChanges()
        observeLockChanges()
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
            cell.configure(with: item, fill: self.browseTab.aspectFill, cornerRadius: self.browseTab.zoom.cornerRadius,
                           lock: self.environment.zoomLockStore.lock(for: item.ocId), store: self.thumbnailStore, client: self.client)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: photoCell, for: indexPath, item: item)
        }
    }

    private func setUpToolbar() {
        // Zoom moved to the bottom bar (it now drives folder grids too); the top bar
        // keeps the flat-gallery-only controls: sort + fit/fill.
        aspectItem = UIBarButtonItem(image: nil, style: .plain, target: self, action: #selector(toggleAspect))
        sortItem = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: makeSortMenu())
        filterItem = UIBarButtonItem(image: nil, menu: makeFilterMenu())
        navigationItem.rightBarButtonItems = [filterItem, aspectItem, sortItem]
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

    /// A toggle per available filter. Multi-select (the menu reopens to flip the
    /// other), matching the AND semantics — an item must satisfy every one that's on.
    private func makeFilterMenu() -> UIMenu {
        let actions = GalleryFilter.options.map { option in
            UIAction(title: option.label, image: UIImage(systemName: option.symbol), state: browseTab.filter.contains(option.filter) ? .on : .off) { [weak self] _ in
                guard let self else { return }
                if browseTab.filter.contains(option.filter) {
                    browseTab.filter.remove(option.filter)
                } else {
                    browseTab.filter.insert(option.filter)
                }
            }
        }
        return UIMenu(title: "Filter", children: actions)
    }

    private func updateToolbar() {
        sortItem.menu = makeSortMenu()
        filterItem.menu = makeFilterMenu()
        // Fill the funnel when any filter is on, so the active state reads at a glance;
        // a plain (circle-free) funnel when off.
        let filtering = !browseTab.filter.isEmpty
        filterItem.image = UIImage(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        aspectItem.image = UIImage(systemName: browseTab.aspectFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
    }

    // MARK: - Observation

    private func observeTab() {
        tabObservation = observeChanges { [weak self] in
            guard let self else { return }
            // Touch the observed properties so changes re-fire this closure.
            let sort = self.browseTab.sort, zoom = self.browseTab.zoom
            let aspectFill = self.browseTab.aspectFill, filter = self.browseTab.filter
            self.apply(sort: sort, zoom: zoom, aspectFill: aspectFill, filter: filter)
        }
    }

    private func apply(sort: GallerySortOrder, zoom: GalleryGridZoom, aspectFill: Bool, filter: GalleryFilter) {
        let sortChanged = sort != appliedSort
        let zoomChanged = zoom != appliedZoom
        let aspectChanged = aspectFill != appliedAspectFill
        let filterChanged = filter != appliedFilter
        // Favorites are toggled in the viewer (a sibling overlay that doesn't refresh
        // this screen), so a cached favorites set goes stale. Re-fetch it whenever the
        // favorites filter is switched on, so a just-favorited photo shows up.
        let favoritesTurnedOn = filter.contains(.favorites) && !appliedFilter.contains(.favorites)
        appliedSort = sort; appliedZoom = zoom; appliedAspectFill = aspectFill; appliedFilter = filter

        updateToolbar()
        // A sort change refetches (and re-filters at the end); a filter-only change
        // just re-filters the items already in hand.
        if sortChanged { reloadFromCache() }
        else if filterChanged { applyFilter() }
        if favoritesTurnedOn { loadFavoritesIfNeeded(force: true) }
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

    /// Re-render a tile when its photo's zoom lock is set or cleared, so the locked
    /// crop appears/disappears without a full reload.
    private func observeLockChanges() {
        lockObserver = NotificationCenter.default.addObserver(
            forName: ZoomLockStore.didChange, object: nil, queue: .main
        ) { [weak self] note in
            let ocId = note.userInfo?["ocId"] as? String
            MainActor.assumeIsolated { self?.reconfigureItem(ocId: ocId) }
        }
    }

    /// Reconfigures the tile for `ocId` (or all tiles when nil) to pick up a lock change.
    private func reconfigureItem(ocId: String?) {
        var snapshot = dataSource.snapshot()
        // Only items still in the snapshot — reconfiguring a stale identifier asserts.
        let targets = snapshot.itemIdentifiers.filter { ocId == nil || $0.ocId == ocId }
        guard !targets.isEmpty else { return }
        snapshot.reconfigureItems(targets)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func reloadFromCache() {
        let sort = appliedSort
        Task {
            let snapshots = (try? await cacheStore.flatItems(under: folderPath, account: account, sort: sort)) ?? []
            self.allItems = snapshots
            applyFilter()
        }
    }

    /// Narrows ``allItems`` to the active filters and pushes the result to the grid.
    /// Zoom-locked is a synchronous lookup in the local store; favorites needs the
    /// account's favorited ids, fetched lazily (see ``loadFavoritesIfNeeded``) — until
    /// they arrive the favorites-filtered result is empty and a spinner shows.
    private func applyFilter() {
        var result = allItems
        if appliedFilter.contains(.zoomLocked) {
            let store = environment.zoomLockStore
            result = result.filter { store.isLocked($0.ocId) }
        }
        if appliedFilter.contains(.favorites) {
            if let favoriteOcIds {
                result = result.filter { favoriteOcIds.contains($0.ocId) }
            } else {
                result = []
                loadFavoritesIfNeeded()
            }
        }
        items = result
        applySnapshot()
        updateStatus()
    }

    /// Fetches the account's favorited ids, then re-applies the filter. Favorites live
    /// on the server (not the cache), so the set is cached for the screen's lifetime and
    /// only re-read when needed: `force` re-fetches an already-loaded set (favorites
    /// changed in the viewer, or the filter was just switched on), keeping the current
    /// results visible while it refreshes; ``load`` (pull-to-refresh) clears it outright.
    private func loadFavoritesIfNeeded(force: Bool = false) {
        guard !isLoadingFavorites else { return }
        if !force, favoriteOcIds != nil { return }
        isLoadingFavorites = true
        favoritesError = nil
        updateStatus()
        Task {
            defer { isLoadingFavorites = false }
            do {
                favoriteOcIds = try await client.favoriteImageOcIds()
            } catch is CancellationError {
                return
            } catch {
                favoritesError = (error as? GalleryError)?.userMessage ?? error.localizedDescription
            }
            applyFilter()
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, GridItemSnapshot>()
        snapshot.appendSections([0])
        snapshot.appendItems(items, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func updateStatus() {
        guard items.isEmpty else { statusView.hide(); return }
        // The favorites set is still resolving — we can't yet say "no favorites".
        if appliedFilter.contains(.favorites), favoriteOcIds == nil, favoritesError == nil {
            statusView.showLoading()
        } else if let favoritesError {
            statusView.showError(symbol: "exclamationmark.triangle", title: "Couldn't load favorites", message: favoritesError)
        } else if allItems.isEmpty, isLoading {
            // Genuine first load: nothing cached yet and the recursive search is running.
            statusView.showLoading()
        } else if let errorMessage, allItems.isEmpty {
            statusView.showError(symbol: "exclamationmark.triangle", title: "Couldn't load", message: errorMessage)
        } else {
            // The cache is populated but the active filter excluded everything. Show the
            // filter's empty state rather than waiting on the background search — if it
            // later turns up a match, the cache observer re-applies the filter.
            let empty = filterEmptyState
            statusView.showEmpty(symbol: empty.symbol, title: empty.title, message: empty.message)
        }
    }

    /// The empty-state copy, tailored to which filters are on so a filtered-out
    /// gallery doesn't read as a genuinely empty folder.
    private var filterEmptyState: (symbol: String, title: String, message: String) {
        switch (appliedFilter.contains(.favorites), appliedFilter.contains(.zoomLocked)) {
        case (true, true): ("line.3.horizontal.decrease.circle", "No Matches", "No favorited, zoom-locked photos here.")
        case (true, false): ("heart", "No Favorites", "No favorited photos here.")
        case (false, true): ("lock", "No Locked Photos", "No zoom-locked photos here.")
        case (false, false): ("photo.on.rectangle", "No Photos", "This folder has no photos.")
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        // A refresh should also re-read favorites (they may have changed server-side).
        favoriteOcIds = nil
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

    /// The item scrolled out of the prefetch window before it finished loading —
    /// cancel it so its download yields the gate to on-screen cells.
    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let item = dataSource.itemIdentifier(for: indexPath), item.hasPreview else { continue }
            ImageLoader.shared.cancelPrefetch(ocId: item.ocId, etag: item.etag, pixels: NextcloudConfig.gridThumbnailPixels)
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
