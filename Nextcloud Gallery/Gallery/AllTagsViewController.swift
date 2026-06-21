//
//  AllTagsViewController.swift
//  Nextcloud Gallery
//
//  The "See All" destination for Home's Tags strip: every system tag as a cover tile
//  (treated like an album). Tapping one opens a gallery of its files.
//

import UIKit
import NextcloudKit

final class AllTagsViewController: UIViewController {
    private let environment: AppEnvironment
    private let client: NextcloudClient
    private weak var navigator: GalleryNavigator?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, TagPreview>!
    private let statusView = GridStatusView()
    private let refreshControl = UIRefreshControl()

    private var tags: [TagPreview] = []
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
        navigationItem.title = "Tags"
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
        let tagCell = UICollectionView.CellRegistration<AlbumGridCell, TagPreview> { [weak self] cell, _, preview in
            guard let self else { return }
            cell.configure(coverFileId: preview.coverFileId, name: preview.tag.name, subtitle: nil,
                           placeholderSymbol: "tag.fill", store: self.thumbnailStore, client: self.client)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, preview in
            collectionView.dequeueConfiguredReusableCell(using: tagCell, for: indexPath, item: preview)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        updateStatus()
        defer { isLoading = false; refreshControl.endRefreshing(); updateStatus() }
        do {
            tags = try await client.tagPreviews()
            var snapshot = NSDiffableDataSourceSnapshot<Int, TagPreview>()
            snapshot.appendSections([0])
            snapshot.appendItems(tags, toSection: 0)
            await dataSource.apply(snapshot, animatingDifferences: true)
        } catch {
            errorMessage = (error as? GalleryError)?.userMessage ?? error.localizedDescription
        }
    }

    private func updateStatus() {
        if isLoading && tags.isEmpty {
            statusView.showLoading()
        } else if let errorMessage, tags.isEmpty {
            statusView.showError(symbol: "exclamationmark.triangle", title: "Couldn't load", message: errorMessage)
        } else if tags.isEmpty {
            statusView.showEmpty(symbol: "tag", title: "No Tags", message: "You don't have any tags yet.")
        } else {
            statusView.hide()
        }
    }

    @objc private func pullToRefresh() { Task { await load() } }
}

extension AllTagsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let preview = dataSource.itemIdentifier(for: indexPath) else { return }
        navigator?.openTag(id: preview.tag.id, name: preview.tag.name)
    }
}
