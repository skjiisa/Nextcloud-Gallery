//
//  AllAlbumsViewController.swift
//  Nextcloud Gallery
//
//  The "See All" destination for Home's Albums strip: every Nextcloud Photos album
//  in a grid of cover tiles. Tapping one opens it via the ``GalleryNavigator``.
//

import UIKit

final class AllAlbumsViewController: UIViewController {
    private let environment: AppEnvironment
    private let client: NextcloudClient
    private weak var navigator: GalleryNavigator?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Album>!
    private let statusView = GridStatusView()
    private let refreshControl = UIRefreshControl()

    private var albums: [Album] = []
    private var isLoading = false
    private var errorMessage: String?
    private var didInitialLoad = false

    private var thumbnailStore: ThumbnailStore { environment.thumbnailStore }

    init(environment: AppEnvironment, client: NextcloudClient, navigator: GalleryNavigator?) {
        self.environment = environment
        self.client = client
        self.navigator = navigator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = "Albums"
        setUpCollectionView()
        setUpStatusView()
        configureDataSource()
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

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, env in
            let spacing: CGFloat = 10, inset: CGFloat = 16, minTile: CGFloat = 170
            let usable = max(0, env.container.effectiveContentSize.width - inset * 2)
            let columns = max(1, Int((usable + spacing) / (minTile + spacing)))
            let fraction = 1.0 / CGFloat(columns)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(fraction), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(fraction)),
                subitems: [item]
            )
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
            return section
        }
    }

    private func setUpCollectionView() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
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
        let albumCell = UICollectionView.CellRegistration<AlbumGridCell, Album> { [weak self] cell, _, album in
            guard let self else { return }
            cell.configure(with: album, store: self.thumbnailStore, client: self.client)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, album in
            collectionView.dequeueConfiguredReusableCell(using: albumCell, for: indexPath, item: album)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        updateStatus()
        defer { isLoading = false; refreshControl.endRefreshing(); updateStatus() }
        do {
            albums = try await client.listAlbums()
            var snapshot = NSDiffableDataSourceSnapshot<Int, Album>()
            snapshot.appendSections([0])
            snapshot.appendItems(albums, toSection: 0)
            await dataSource.apply(snapshot, animatingDifferences: true)
        } catch {
            errorMessage = (error as? GalleryError)?.userMessage ?? error.localizedDescription
        }
    }

    private func updateStatus() {
        if isLoading && albums.isEmpty {
            statusView.showLoading()
        } else if let errorMessage, albums.isEmpty {
            statusView.showError(symbol: "exclamationmark.triangle", title: "Couldn't load", message: errorMessage)
        } else if albums.isEmpty {
            statusView.showEmpty(symbol: "rectangle.stack", title: "No Albums", message: "You don't have any albums yet.")
        } else {
            statusView.hide()
        }
    }

    @objc private func pullToRefresh() { Task { await load() } }
}

extension AllAlbumsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let album = dataSource.itemIdentifier(for: indexPath) else { return }
        navigator?.openAlbum(album)
    }
}
