//
//  BrowseNavController.swift
//  Nextcloud Gallery
//
//  One tab's page: a navigation controller rooted at the Files-root folder grid,
//  with the tab's Liquid Glass bottom bar floating above the content. Uses the
//  normal navigation stack (the standard top-bar back button); the bottom bar holds
//  the reach-friendly actions (zoom, gallery toggle, new tab, settings) and the tab
//  switcher handle. Keeps ``BrowseTab/path`` in sync for restore + the switcher.
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
        bar.onZoomOut = { [weak self] in guard let self else { return }; browseTab.zoom = browseTab.zoom.zoomedOut }
        bar.onZoomIn = { [weak self] in guard let self else { return }; browseTab.zoom = browseTab.zoom.zoomedIn }
        bar.onGalleryToggle = { [weak self] in self?.toggleGallery() }
        bar.onNewTab = { [weak self] in self?.tabsModel.newTab() }
        bar.onSettings = { [weak self] in self?.tabsModel.isShowingSettings = true }
        bar.onShowTabs = { [weak self] in self?.tabsModel.openSwitcher() }
        bar.onDragChanged = { [weak self] tx in self?.dragHandler?.carouselDragChanged(translation: tx) }
        bar.onDragEnded = { [weak self] tx in self?.dragHandler?.carouselDragEnded(translation: tx) }
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            bar.heightAnchor.constraint(equalToConstant: GlassTabBar.preferredHeight),
        ])

        barObservation = observeChanges { [weak self] in self?.updateBarState() }
    }

    /// Refreshes the bar from current navigation + tab state. Reads observable state
    /// (title, count, warming, zoom) so the observation re-fires on their change, and
    /// is also called on navigation events for the non-observable stack state.
    private func updateBarState() {
        let warming = environment.warmingCoordinator?.state == .warming
        let galleryEnabled = (topViewController as? FolderGridViewController)?.hasSubfolders ?? false
        bar.configure(
            title: browseTab.title,
            count: tabsModel.tabs.count,
            isWarming: warming,
            galleryEnabled: galleryEnabled,
            canZoomIn: browseTab.zoom.canZoomIn,
            canZoomOut: browseTab.zoom.canZoomOut
        )
    }

    // MARK: - Destinations

    private func makeViewController(forRoot: Bool, route: BrowseRoute?) -> UIViewController {
        if forRoot {
            return makeFolderGrid(folderPath: client.filesRootPath, title: "Photos", account: client.credentials.account)
        }
        switch route! {
        case .folder(let r):
            return makeFolderGrid(folderPath: r.folderPath, title: r.title, account: r.account)
        case .flat(let r):
            return FlatGalleryViewController(folderPath: r.folderPath, title: r.title, account: r.account, environment: environment, client: client, tab: browseTab, navigator: self)
        }
    }

    private func makeFolderGrid(folderPath: String, title: String, account: String) -> FolderGridViewController {
        let grid = FolderGridViewController(folderPath: folderPath, title: title, account: account, environment: environment, client: client, tab: browseTab, navigator: self)
        // Subfolders may appear after a load → refresh the Gallery toggle state.
        grid.onContentChanged = { [weak self, weak grid] in
            guard let self, self.topViewController === grid else { return }
            self.updateBarState()
        }
        return grid
    }

    // MARK: - Navigation

    private func navigate(to route: BrowseRoute) {
        browseTab.path.append(route)
        tabsModel.save()
        pushViewController(makeViewController(forRoot: false, route: route), animated: true)
    }

    /// Flattens the current folder into the gallery (only meaningful when a browse
    /// grid with subfolders is showing — the bar disables the button otherwise).
    private func toggleGallery() {
        guard topViewController is FolderGridViewController else { return }
        let (path, title, account): (String, String, String)
        if let last = browseTab.path.last, case .folder(let r) = last {
            (path, title, account) = (r.folderPath, r.title, r.account)
        } else {
            (path, title, account) = (client.filesRootPath, "Photos", client.credentials.account)
        }
        navigate(to: .flat(FlatGalleryRoute(folderPath: path, title: title, account: account)))
    }

    /// Whether the cached structure says a folder has no subfolders (so it should
    /// open straight into the flattened gallery). Unknown structure → browse.
    private func isLeafFolder(_ route: FolderRoute) async -> Bool {
        let store = environment.cacheStore
        guard (try? await store.isListed(path: route.folderPath, account: route.account)) == true else { return false }
        let hasSub = (try? await store.hasSubfolders(folderPath: route.folderPath, account: route.account)) ?? true
        return !hasSub
    }
}

// MARK: - GalleryNavigator

extension BrowseNavController: GalleryNavigator {
    func openFolder(_ route: FolderRoute) {
        Task {
            if await isLeafFolder(route) {
                navigate(to: .flat(FlatGalleryRoute(folderPath: route.folderPath, title: route.title, account: route.account)))
            } else {
                navigate(to: .folder(route))
            }
        }
    }

    func openFolderInNewTab(_ route: FolderRoute) { tabsModel.open(.folder(route), inNewTab: true) }
    func openViewer(photos: [PhotoItem], initialID: String, source: (any PhotoViewerTransitionSource)?) {
        browseTab.openViewer(photos: photos, initialID: initialID, source: source)
    }
}

// MARK: - UINavigationControllerDelegate

extension BrowseNavController: UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        // Keep content clear of the floating bar.
        viewController.additionalSafeAreaInsets.bottom = GlassTabBar.preferredHeight + 4
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        // A pop (back button / edge-swipe) leaves fewer VCs than path entries — trim
        // the path so it persists and the switcher title is correct.
        let depth = viewControllers.count - 1
        if depth < browseTab.path.count {
            browseTab.path = Array(browseTab.path.prefix(depth))
            tabsModel.save()
        }
        updateBarState()
    }
}
