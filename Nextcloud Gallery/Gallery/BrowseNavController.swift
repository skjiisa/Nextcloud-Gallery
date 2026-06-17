//
//  BrowseNavController.swift
//  Nextcloud Gallery
//
//  One tab's page: a navigation controller rooted at the Files-root folder grid,
//  with the tab's own Liquid Glass bottom bar floating above the content. Owns the
//  tab's navigation history (kept in sync with ``BrowseTab/path`` for restore + the
//  switcher title) and acts as the ``GalleryNavigator`` for the grids it hosts.
//

import UIKit

/// Receives a tab bar's horizontal drag so the carousel can slide between tabs.
@MainActor
protocol CarouselDragHandling: AnyObject {
    func carouselDragChanged(translation: CGFloat)
    func carouselDragEnded(translation: CGFloat)
}

final class BrowseNavController: UINavigationController {
    let browseTab: BrowseTab
    private let environment: AppEnvironment
    private let client: NextcloudClient
    private let tabsModel: TabsModel
    private weak var dragHandler: CarouselDragHandling?

    private let bar = GlassTabBar()
    private var barObservation: ObservationToken?
    private var syncingFromPath = false

    init(tab: BrowseTab, environment: AppEnvironment, client: NextcloudClient, tabsModel: TabsModel, dragHandler: CarouselDragHandling?) {
        self.browseTab = tab
        self.environment = environment
        self.client = client
        self.tabsModel = tabsModel
        self.dragHandler = dragHandler
        super.init(nibName: nil, bundle: nil)

        // Build the VC stack: Files-root grid + each persisted route.
        let root = makeViewController(forRoot: true, route: nil)
        let pushed = browseTab.path.map { makeViewController(forRoot: false, route: $0) }
        setViewControllers([root] + pushed, animated: false)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpBar()
    }

    // MARK: - Bar

    private func setUpBar() {
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onNewTab = { [weak self] in self?.tabsModel.newTab() }
        bar.onShowTabs = { [weak self] in self?.tabsModel.openSwitcher() }
        bar.onSettings = { [weak self] in self?.tabsModel.isShowingSettings = true }
        bar.onDragChanged = { [weak self] tx in self?.dragHandler?.carouselDragChanged(translation: tx) }
        bar.onDragEnded = { [weak self] tx in self?.dragHandler?.carouselDragEnded(translation: tx) }
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            bar.heightAnchor.constraint(equalToConstant: GlassTabBar.preferredHeight),
        ])

        barObservation = observeChanges { [weak self] in
            guard let self else { return }
            let warming = self.environment.warmingCoordinator?.state == .warming
            self.bar.configure(title: self.browseTab.title, count: self.tabsModel.tabs.count, isWarming: warming)
        }
    }

    // MARK: - Destinations

    private func makeViewController(forRoot: Bool, route: BrowseRoute?) -> UIViewController {
        if forRoot {
            return FolderGridViewController(
                folderPath: client.filesRootPath, title: "Photos", account: client.credentials.account,
                environment: environment, client: client, navigator: self
            )
        }
        switch route! {
        case .folder(let r):
            return FolderGridViewController(folderPath: r.folderPath, title: r.title, account: r.account, environment: environment, client: client, navigator: self)
        case .flat(let r):
            return FlatGalleryViewController(folderPath: r.folderPath, title: r.title, account: r.account, environment: environment, client: client, tab: browseTab, navigator: self)
        }
    }

    private func push(_ route: BrowseRoute) {
        browseTab.path.append(route)
        tabsModel.save()
        pushViewController(makeViewController(forRoot: false, route: route), animated: true)
    }
}

// MARK: - GalleryNavigator

extension BrowseNavController: GalleryNavigator {
    func openFolder(_ route: FolderRoute) { push(.folder(route)) }
    func openFlatGallery(_ route: FlatGalleryRoute) { push(.flat(route)) }
    func openFolderInNewTab(_ route: FolderRoute) { tabsModel.open(.folder(route), inNewTab: true) }
    func openViewer(photos: [PhotoItem], initialID: String, source: (any PhotoViewerTransitionSource)?) {
        browseTab.openViewer(photos: photos, initialID: initialID, source: source)
    }
}

// MARK: - UINavigationControllerDelegate

extension BrowseNavController: UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        // Keep content clear of the floating bar.
        viewController.additionalSafeAreaInsets.bottom = GlassTabBar.preferredHeight + 4

        // A pop (back button / swipe) leaves fewer VCs than path entries — truncate
        // the path to match so it persists and the switcher title is correct.
        let depth = viewControllers.count - 1
        if depth < browseTab.path.count {
            browseTab.path = Array(browseTab.path.prefix(depth))
            tabsModel.save()
        }
    }
}
