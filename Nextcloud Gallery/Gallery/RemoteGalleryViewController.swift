//
//  RemoteGalleryViewController.swift
//  Nextcloud Gallery
//
//  A flat photo gallery backed by a one-shot async fetch rather than the SwiftData
//  cache. Used for surfaces that aren't part of the warmed folder tree — the
//  account's Favorites and the contents of a Photos album — both of which arrive as
//  ready-to-render ``GridItemSnapshot`` values. Mirrors ``FlatGalleryViewController``
//  (same cell, zoom/aspect from the ``BrowseTab``, viewer transition) minus the
//  cache/search/sort machinery.
//

import UIKit

final class RemoteGalleryViewController: UIViewController {
    typealias Fetch = () async throws -> [GridItemSnapshot]

    private let galleryTitle: String
    private let account: String
    private let environment: AppEnvironment
    private let client: NextcloudClient
    private let browseTab: BrowseTab
    private weak var navigator: GalleryNavigator?
    private let fetch: Fetch

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, GridItemSnapshot>!
    private let statusView = GridStatusView()
    private let refreshControl = UIRefreshControl()

    private var items: [GridItemSnapshot] = []
    private var isLoading = false
    private var errorMessage: String?
    private var didInitialLoad = false
    private var tabObservation: ObservationToken?

    private var appliedZoom: GalleryGridZoom
    private var appliedAspectFill: Bool

    private var aspectItem: UIBarButtonItem!

    /// Tight, Photos-style inter-tile gap and outer margin.
    private let tileSpacing: CGFloat = 2

    private var thumbnailStore: ThumbnailStore { environment.thumbnailStore }

    init(
        title: String, account: String, environment: AppEnvironment, client: NextcloudClient,
        tab: BrowseTab, navigator: GalleryNavigator?, fetch: @escaping Fetch
    ) {
        self.galleryTitle = title
        self.account = account
        self.environment = environment
        self.client = client
        self.browseTab = tab
        self.navigator = navigator
        self.fetch = fetch
        self.appliedZoom = tab.zoom
        self.appliedAspectFill = tab.aspectFill
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = galleryTitle

        setUpCollectionView()
        setUpStatusView()
        configureDataSource()
        setUpToolbar()
        observeTab()

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.collectionView.setCollectionViewLayout(self.makeLayout(), animated: false)
        }
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
        navigationItem.rightBarButtonItem = aspectItem
        updateToolbar()
    }

    private func updateToolbar() {
        aspectItem.image = UIImage(systemName: browseTab.aspectFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
    }

    // MARK: - Observation

    private func observeTab() {
        tabObservation = observeChanges { [weak self] in
            guard let self else { return }
            // Touch the observed properties so changes re-fire this closure.
            let zoom = self.browseTab.zoom, aspectFill = self.browseTab.aspectFill
            self.apply(zoom: zoom, aspectFill: aspectFill)
        }
    }

    private func apply(zoom: GalleryGridZoom, aspectFill: Bool) {
        let zoomChanged = zoom != appliedZoom
        let aspectChanged = aspectFill != appliedAspectFill
        appliedZoom = zoom; appliedAspectFill = aspectFill
        updateToolbar()
        guard zoomChanged || aspectChanged else { return }

        let newLayout = zoomChanged ? makeLayout() : nil
        let cells = collectionView.visibleCells.compactMap { $0 as? PhotoGridCell }
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3, options: [.allowUserInteraction]) {
            if let newLayout { self.collectionView.setCollectionViewLayout(newLayout, animated: false) }
            for cell in cells { cell.applyAppearance(fill: aspectFill, cornerRadius: zoom.cornerRadius) }
            self.collectionView.layoutIfNeeded()
        }
    }

    // MARK: - Data

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
            statusView.showEmpty(symbol: "photo.on.rectangle", title: "No Photos", message: "There's nothing here yet.")
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
            items = try await fetch()
            applySnapshot()
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

extension RemoteGalleryViewController: UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
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

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let item = dataSource.itemIdentifier(for: indexPath), item.hasPreview else { continue }
            ImageLoader.shared.cancelPrefetch(ocId: item.ocId, etag: item.etag, pixels: NextcloudConfig.gridThumbnailPixels)
        }
    }
}

// MARK: - Viewer transition source

extension RemoteGalleryViewController: PhotoViewerTransitionSource {
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
