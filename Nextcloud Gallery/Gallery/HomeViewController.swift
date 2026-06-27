//
//  HomeViewController.swift
//  Nextcloud Gallery
//
//  The root of every tab's navigation stack. A hub of horizontally-scrolling sections:
//  a row of file-browser buttons (the Media folder as a gallery / folder, the root
//  folder, or — until a Media folder is set — a "Set Media Folder" button), then strips
//  of Favorites, Albums, and Tags, each with a "See All". Favorites/albums/tags are
//  read live (see ``NextcloudClient`` extensions) and each opens via ``GalleryNavigator``.
//

import UIKit
import NextcloudKit

final class HomeViewController: UIViewController {
    // `nonisolated` so their Hashable conformance is Sendable — diffable identifiers
    // must be, and a type nested in this main-actor class otherwise isn't.
    private nonisolated enum Section: Hashable { case browser, favorites, albums, tags }
    private nonisolated enum Item: Hashable {
        case button(HomeButton)
        case favorite(GridItemSnapshot)
        case album(Album)
        case tag(TagPreview)
    }

    /// A file-browser button on the Home row.
    private nonisolated enum HomeButton: Hashable {
        case mediaGallery, mediaFolder, rootFolder, setMediaFolder

        var icon: String {
            switch self {
            case .mediaGallery: "photo.stack.fill"
            case .mediaFolder: "folder.fill"
            case .rootFolder: "externaldrive.fill"
            case .setMediaFolder: "folder.badge.plus"
            }
        }
        var title: String {
            switch self {
            case .mediaGallery: "Gallery"
            case .mediaFolder: "Browse"
            case .rootFolder: "All Files"
            case .setMediaFolder: "Set Media Folder"
            }
        }
    }

    private let environment: AppEnvironment
    private let client: NextcloudClient
    private weak var navigator: GalleryNavigator?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let refreshControl = UIRefreshControl()

    private var buttons: [HomeButton] = []
    private var favorites: [GridItemSnapshot] = []
    private var albums: [Album] = []
    private var tags: [TagPreview] = []
    /// Cover tiles for the media folder: the first feeds the Gallery button's single
    /// cover; all of them feed the Browse button's 2x2 folder composite.
    private var mediaCoverTiles: [CoverTile] = []
    private var didInitialLoad = false
    private var mediaObserver: NSObjectProtocol?

    /// How many items each strip previews ("See All" opens the rest).
    private let stripLimit = 12

    private var account: String { client.credentials.account }
    private var thumbnailStore: ThumbnailStore { environment.thumbnailStore }

    init(environment: AppEnvironment, client: NextcloudClient, navigator: GalleryNavigator?) {
        self.environment = environment
        self.client = client
        self.navigator = navigator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let mediaObserver { NotificationCenter.default.removeObserver(mediaObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = "Home"

        setUpCollectionView()
        configureDataSource()
        refreshButtons()
        applySnapshot()   // show the browser buttons immediately

        // Rebuild the buttons when the media folder is set or cleared.
        mediaObserver = NotificationCenter.default.addObserver(
            forName: MediaFolder.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mediaCoverTiles = []
                self.refreshButtons()
                self.applySnapshot()
                self.collectionView.collectionViewLayout.invalidateLayout()
                Task { await self.refreshMediaCover() }
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !didInitialLoad {
            didInitialLoad = true
            Task { await load() }
        }
    }

    // MARK: - Browser buttons

    /// The buttons shown in the file-browser row, per the Media folder setting:
    /// none set → [Set Media Folder, All Files]; set to root → [Gallery, Browse];
    /// set to a subfolder → [Gallery, Browse, All Files].
    private func computeButtons() -> [HomeButton] {
        guard let media = MediaFolder.path(account: account) else {
            return [.setMediaFolder, .rootFolder]
        }
        if WebDAVPath.normalized(media) == WebDAVPath.normalized(client.filesRootPath) {
            return [.mediaGallery, .mediaFolder]
        }
        return [.mediaGallery, .mediaFolder, .rootFolder]
    }

    private func refreshButtons() { buttons = computeButtons() }

    // MARK: - Layout

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
            case .browser: return self.browserSection(env)
            case .favorites: return self.favoritesSection()
            case .albums: return self.albumsSection()
            case .tags: return self.tagsSection()
            }
        }
    }

    private func browserSection(_ env: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let count = max(1, buttons.count)
        let spacing: CGFloat = 10, inset: CGFloat = 16
        let usable = max(0, env.container.effectiveContentSize.width - inset * 2)
        let itemWidth = (usable - spacing * CGFloat(count - 1)) / CGFloat(count)
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(itemWidth), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(104)),
            subitems: [item]
        )
        group.interItemSpacing = .fixed(spacing)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: inset, bottom: 8, trailing: inset)
        return section
    }

    /// A horizontal strip of fixed-size tiles + a "See All" header — the shared shape
    /// for Favorites, Albums, and Tags.
    private func stripSection(tile: CGSize, estimated: Bool, spacing: CGFloat, bottom: CGFloat) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let groupWidth: NSCollectionLayoutDimension = estimated ? .estimated(tile.width) : .absolute(tile.width)
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: groupWidth, heightDimension: .absolute(tile.height)),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.orthogonalScrollingBehavior = .continuous
        section.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 16, bottom: bottom, trailing: 16)
        section.boundarySupplementaryItems = [headerItem()]
        return section
    }

    private func favoritesSection() -> NSCollectionLayoutSection {
        stripSection(tile: CGSize(width: 112, height: 112), estimated: false, spacing: 6, bottom: 12)
    }

    private func albumsSection() -> NSCollectionLayoutSection {
        stripSection(tile: CGSize(width: 150, height: 150), estimated: false, spacing: 8, bottom: 16)
    }

    private func tagsSection() -> NSCollectionLayoutSection {
        // Tags are rendered like albums — cover tiles in a strip.
        stripSection(tile: CGSize(width: 150, height: 150), estimated: false, spacing: 8, bottom: 20)
    }

    private func headerItem() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(44)),
            elementKind: HomeHeaderView.kind, alignment: .top
        )
    }

    // MARK: - Data source

    private func configureDataSource() {
        let buttonCell = UICollectionView.CellRegistration<HomeButtonCell, HomeButton> { [weak self] cell, _, button in
            guard let self else { return }
            // Gallery shows the media folder's newest photo; Browse shows its 2x2 folder
            // composite; All Files / Set Media Folder show their SF icon.
            let coverTiles: [CoverTile]
            switch button {
            case .mediaGallery: coverTiles = Array(self.mediaCoverTiles.prefix(1))
            case .mediaFolder: coverTiles = self.mediaCoverTiles
            default: coverTiles = []
            }
            cell.configure(icon: button.icon, title: button.title, coverTiles: coverTiles,
                           asFolder: button == .mediaFolder, store: self.thumbnailStore, client: self.client)
        }
        let favoriteCell = UICollectionView.CellRegistration<PhotoGridCell, GridItemSnapshot> { [weak self] cell, _, item in
            guard let self else { return }
            cell.configure(with: item, fill: true, cornerRadius: 10,
                           lock: self.environment.zoomLockStore.lock(for: item.ocId), store: self.thumbnailStore, client: self.client)
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
        let tagCell = UICollectionView.CellRegistration<AlbumGridCell, TagPreview> { [weak self] cell, _, preview in
            guard let self else { return }
            cell.configure(coverFileId: preview.coverFileId, name: preview.tag.name, subtitle: nil,
                           placeholderSymbol: "tag.fill", store: self.thumbnailStore, client: self.client)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .button(let button):
                return collectionView.dequeueConfiguredReusableCell(using: buttonCell, for: indexPath, item: button)
            case .favorite(let snapshot):
                if snapshot.isDirectory {
                    return collectionView.dequeueConfiguredReusableCell(using: favoriteFolderCell, for: indexPath, item: snapshot)
                }
                return collectionView.dequeueConfiguredReusableCell(using: favoriteCell, for: indexPath, item: snapshot)
            case .album(let album):
                return collectionView.dequeueConfiguredReusableCell(using: albumCell, for: indexPath, item: album)
            case .tag(let preview):
                return collectionView.dequeueConfiguredReusableCell(using: tagCell, for: indexPath, item: preview)
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<HomeHeaderView>(elementKind: HomeHeaderView.kind) { [weak self] header, _, indexPath in
            guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            switch section {
            case .favorites:
                header.configure(title: "Favorites", actionTitle: "See All") { [weak self] in self?.navigator?.openFavorites() }
            case .albums:
                header.configure(title: "Albums", actionTitle: "See All") { [weak self] in self?.navigator?.openAllAlbums() }
            case .tags:
                header.configure(title: "Tags", actionTitle: "See All") { [weak self] in self?.navigator?.openAllTags() }
            case .browser:
                header.configure(title: "", actionTitle: nil, onAction: nil)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.browser])
        snapshot.appendItems(buttons.map(Item.button), toSection: .browser)
        if !favorites.isEmpty {
            snapshot.appendSections([.favorites])
            snapshot.appendItems(favorites.prefix(stripLimit).map(Item.favorite), toSection: .favorites)
        }
        if !albums.isEmpty {
            snapshot.appendSections([.albums])
            snapshot.appendItems(albums.prefix(stripLimit).map(Item.album), toSection: .albums)
        }
        if !tags.isEmpty {
            snapshot.appendSections([.tags])
            snapshot.appendItems(tags.prefix(stripLimit).map(Item.tag), toSection: .tags)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func load() async {
        // Favorites, albums, tags, and the media cover are independent best-effort
        // fetches; any can fail (or be empty) without affecting the always-present buttons.
        async let favoritesResult = client.favorites()
        async let albumsResult = client.listAlbums()
        async let tagsResult = client.tagPreviews()
        async let mediaCoverResult = fetchMediaCoverTiles()
        favorites = (try? await favoritesResult) ?? favorites
        albums = (try? await albumsResult) ?? albums
        tags = (try? await tagsResult) ?? tags
        mediaCoverTiles = await mediaCoverResult
        refreshControl.endRefreshing()
        applySnapshot()
        reconfigureButtons()   // surface the media covers on their buttons
    }

    @objc private func pullToRefresh() { Task { await load() } }

    /// Up to 4 cover tiles for the current media folder (empty if none is set).
    private func fetchMediaCoverTiles() async -> [CoverTile] {
        guard let media = MediaFolder.path(account: account) else { return [] }
        return (try? await client.folderCoverTiles(path: media, limit: 4)) ?? []
    }

    private func refreshMediaCover() async {
        mediaCoverTiles = await fetchMediaCoverTiles()
        reconfigureButtons()
    }

    /// Reconfigures the (unchanged) button items so their media covers refresh.
    private func reconfigureButtons() {
        var snapshot = dataSource.snapshot()
        let items = buttons.map(Item.button).filter { snapshot.indexOfItem($0) != nil }
        guard !items.isEmpty else { return }
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Actions

    private func handleButton(_ button: HomeButton) {
        let mediaPath = MediaFolder.path(account: account) ?? client.filesRootPath
        let isRoot = WebDAVPath.normalized(mediaPath) == WebDAVPath.normalized(client.filesRootPath)
        let mediaTitle = isRoot ? "Files" : WebDAVPath.displayName(of: mediaPath)
        switch button {
        case .mediaGallery:
            navigator?.openFolder(FolderRoute(folderPath: mediaPath, title: mediaTitle, account: account), mode: .flat)
        case .mediaFolder:
            navigator?.openFolder(FolderRoute(folderPath: mediaPath, title: mediaTitle, account: account), mode: .browse)
        case .rootFolder:
            navigator?.openFolder(FolderRoute(folderPath: client.filesRootPath, title: "Files", account: account), mode: .browse)
        case .setMediaFolder:
            presentFolderPicker()
        }
    }

    private func presentFolderPicker() {
        let account = self.account
        let picker = FolderPickerViewController(folderPath: client.filesRootPath, title: "Files", isRoot: true, client: client) { [weak self] path, _ in
            MediaFolder.setPath(path, account: account)   // posts didChange → buttons rebuild
            self?.presentedViewController?.dismiss(animated: true)
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }
}

// MARK: - Selection

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .button(let button):
            handleButton(button)
        case .favorite(let snapshot):
            if snapshot.isDirectory {
                navigator?.openFolder(FolderRoute(folderPath: snapshot.fullPath, title: snapshot.fileName, account: account), mode: nil)
            } else {
                // Page through every favorite photo (not just the strip's preview); a
                // fade is used since the strip cell isn't a full-grid transition source.
                let photos = favorites.filter { !$0.isDirectory }.map(PhotoItem.init(snapshot:))
                navigator?.openViewer(photos: photos, initialID: snapshot.ocId, source: nil)
            }
        case .album(let album):
            navigator?.openAlbum(album)
        case .tag(let preview):
            navigator?.openTag(id: preview.tag.id, name: preview.tag.name)
        }
    }
}
