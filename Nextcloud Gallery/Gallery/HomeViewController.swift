//
//  HomeViewController.swift
//  Nextcloud Gallery
//
//  The root of every tab's navigation stack. Replaces "drop straight into the Files
//  root" with a hub: a link into the Files folder tree, a strip of the account's
//  Nextcloud favorites, a grid of Nextcloud Photos albums, and a list of system tags.
//  Favorites, albums, and tags are read live (see ``NextcloudClient`` extensions) —
//  they aren't part of the warmed folder cache — and each opens as a flat gallery via
//  the ``GalleryNavigator``.
//

import UIKit
import NextcloudKit

final class HomeViewController: UIViewController {
    // `nonisolated` so their Hashable conformance is Sendable — diffable data source
    // identifiers must be, and a type nested in this main-actor class otherwise isn't.
    private nonisolated enum Section: Hashable { case library, favorites, albums, tags }
    private nonisolated enum Item: Hashable {
        case filesLink
        case favorite(GridItemSnapshot)
        case album(Album)
        case tag(NKTag)
    }

    private let environment: AppEnvironment
    private let client: NextcloudClient
    private weak var navigator: GalleryNavigator?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let refreshControl = UIRefreshControl()

    private var favorites: [GridItemSnapshot] = []
    private var albums: [Album] = []
    private var tags: [NKTag] = []
    private var didInitialLoad = false

    /// How many favorites the Home strip previews ("See All" opens the rest).
    private let favoritesStripLimit = 12

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
        navigationItem.title = "Home"

        setUpCollectionView()
        configureDataSource()
        applySnapshot()   // show the Files link immediately
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !didInitialLoad {
            didInitialLoad = true
            Task { await load() }
        }
    }

    // MARK: - Setup

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

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, env in
            guard let self, let section = self.dataSource?.sectionIdentifier(for: index) else { return nil }
            switch section {
            case .library: return self.librarySection(env)
            case .favorites: return self.favoritesSection()
            case .albums: return self.albumsSection(env)
            case .tags: return self.tagsSection(env)
            }
        }
    }

    private func librarySection(_ env: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        return NSCollectionLayoutSection.list(using: config, layoutEnvironment: env)
    }

    private func tagsSection(_ env: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: env)
        section.boundarySupplementaryItems = [headerItem()]
        return section
    }

    private func favoritesSection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(112), heightDimension: .absolute(112)),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 6
        section.orthogonalScrollingBehavior = .continuous
        section.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 16, bottom: 12, trailing: 16)
        section.boundarySupplementaryItems = [headerItem()]
        return section
    }

    private func albumsSection(_ env: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let spacing: CGFloat = 10
        let inset: CGFloat = 16
        let minTile: CGFloat = 170
        let usable = max(0, env.container.effectiveContentSize.width - inset * 2)
        let columns = max(1, Int((usable + spacing) / (minTile + spacing)))

        // Same proven fractional grid as ``GalleryGridLayout``: a 1/columns-wide item
        // repeated across a full-width group (square via the group's fractional height).
        // `repeatingSubitem:count:` was wrong here — it laid full-width tiles out of bounds.
        let fraction = 1.0 / CGFloat(columns)
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(fraction), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(fraction)),
            subitems: [item]
        )
        group.interItemSpacing = .fixed(spacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: inset, bottom: 24, trailing: inset)
        section.boundarySupplementaryItems = [headerItem()]
        return section
    }

    private func headerItem() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(44)),
            elementKind: HomeHeaderView.kind, alignment: .top
        )
    }

    private func configureDataSource() {
        let filesCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = cell.defaultContentConfiguration()
            content.text = "Files"
            content.secondaryText = "Browse all folders"
            content.image = UIImage(systemName: "folder")
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        let favoriteCell = UICollectionView.CellRegistration<PhotoGridCell, GridItemSnapshot> { [weak self] cell, _, item in
            guard let self else { return }
            cell.configure(with: item, fill: true, cornerRadius: 10, store: self.thumbnailStore, client: self.client)
        }
        // Favorites can include folders; render those as folder tiles in the strip.
        let favoriteFolderCell = UICollectionView.CellRegistration<FolderGridCell, GridItemSnapshot> { [weak self] cell, _, item in
            guard let self else { return }
            cell.configure(with: item, store: self.thumbnailStore, client: self.client)
        }
        let albumCell = UICollectionView.CellRegistration<AlbumGridCell, Album> { [weak self] cell, _, album in
            guard let self else { return }
            cell.configure(with: album, store: self.thumbnailStore, client: self.client)
        }
        let tagCell = UICollectionView.CellRegistration<UICollectionViewListCell, NKTag> { cell, _, tag in
            var content = cell.defaultContentConfiguration()
            content.text = tag.name
            content.image = UIImage(systemName: "tag.fill")
            content.imageProperties.tintColor = tag.color.flatMap(UIColor.init(hex:)) ?? .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .filesLink:
                return collectionView.dequeueConfiguredReusableCell(using: filesCell, for: indexPath, item: item)
            case .favorite(let snapshot):
                if snapshot.isDirectory {
                    return collectionView.dequeueConfiguredReusableCell(using: favoriteFolderCell, for: indexPath, item: snapshot)
                }
                return collectionView.dequeueConfiguredReusableCell(using: favoriteCell, for: indexPath, item: snapshot)
            case .album(let album):
                return collectionView.dequeueConfiguredReusableCell(using: albumCell, for: indexPath, item: album)
            case .tag(let tag):
                return collectionView.dequeueConfiguredReusableCell(using: tagCell, for: indexPath, item: tag)
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<HomeHeaderView>(elementKind: HomeHeaderView.kind) { [weak self] header, _, indexPath in
            guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            switch section {
            case .favorites:
                header.configure(title: "Favorites", actionTitle: "See All") { [weak self] in self?.navigator?.openFavorites() }
            case .albums:
                header.configure(title: "Albums", actionTitle: nil, onAction: nil)
            case .tags:
                header.configure(title: "Tags", actionTitle: nil, onAction: nil)
            case .library:
                header.configure(title: "", actionTitle: nil, onAction: nil)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    // MARK: - Data

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.library])
        snapshot.appendItems([.filesLink], toSection: .library)
        if !favorites.isEmpty {
            snapshot.appendSections([.favorites])
            snapshot.appendItems(favorites.prefix(favoritesStripLimit).map(Item.favorite), toSection: .favorites)
        }
        if !albums.isEmpty {
            snapshot.appendSections([.albums])
            snapshot.appendItems(albums.map(Item.album), toSection: .albums)
        }
        if !tags.isEmpty {
            snapshot.appendSections([.tags])
            snapshot.appendItems(tags.map(Item.tag), toSection: .tags)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func load() async {
        // Favorites, albums, and tags are independent best-effort fetches; any can fail
        // (or be empty) without affecting the others or the always-present Files link.
        async let favoritesResult = client.favorites()
        async let albumsResult = client.listAlbums()
        async let tagsResult = client.availableTags()
        favorites = (try? await favoritesResult) ?? favorites
        albums = (try? await albumsResult) ?? albums
        tags = (try? await tagsResult) ?? tags
        refreshControl.endRefreshing()
        applySnapshot()
    }

    @objc private func pullToRefresh() { Task { await load() } }
}

// MARK: - Selection

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .filesLink:
            navigator?.openFolder(FolderRoute(folderPath: client.filesRootPath, title: "Files", account: client.credentials.account))
        case .favorite(let snapshot):
            if snapshot.isDirectory {
                navigator?.openFolder(FolderRoute(folderPath: snapshot.fullPath, title: snapshot.fileName, account: client.credentials.account))
            } else {
                // Page through every favorite photo (not just the strip's preview); a
                // fade is used since the strip cell isn't a full-grid transition source.
                let photos = favorites.filter { !$0.isDirectory }.map(PhotoItem.init(snapshot:))
                navigator?.openViewer(photos: photos, initialID: snapshot.ocId, source: nil)
            }
        case .album(let album):
            navigator?.openAlbum(album)
        case .tag(let tag):
            navigator?.openTag(id: tag.id, name: tag.name)
        }
    }
}
