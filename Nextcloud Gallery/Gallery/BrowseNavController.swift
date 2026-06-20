//
//  BrowseNavController.swift
//  Nextcloud Gallery
//
//  One tab's page. Hosts a child ``UINavigationController`` (rooted at the Home hub)
//  with the tab's Liquid Glass bottom bar — and, when a photo is open,
//  the photo viewer — floating *above* the nav as siblings. It is deliberately a plain
//  view controller wrapping a nav controller rather than a `UINavigationController`
//  subclass: a `UINavigationController` re-manages the subviews of its own view (it
//  wraps content in transition containers and reorders on layout), which ejects any
//  full-screen overlay added directly to it. Keeping the bar + viewer as siblings of
//  the nav's view means they ride the carousel and stay put.
//
//  Navigation uses the normal stack (the standard top-bar back button); the bottom bar
//  holds the reach-friendly actions (zoom, gallery toggle, new tab, settings) and the
//  tab switcher handle. The embedded viewer rides the carousel and persists per tab
//  (see ``RootCarouselViewController``). Keeps ``BrowseTab/path`` in sync for restore.
//

import UIKit

/// Receives a tab bar's horizontal drag so the carousel can slide between tabs.
@MainActor
protocol CarouselDragHandling: AnyObject {
    func carouselDragChanged(translation: CGFloat)
    /// `velocity` is the finger's horizontal speed (pts/sec) at release, so a quick
    /// flick can switch tabs on little travel and carry its momentum into the snap.
    func carouselDragEnded(translation: CGFloat, velocity: CGFloat)
    /// Park the carousel at the active tab *immediately* (no animation) so a card
    /// snapshot taken now is clean, remembering where the finger left it.
    func carouselParkForSnapshot()
    /// Spring the carousel from the parked position back to the active tab, so a drag
    /// that opens the switcher bounces home instead of popping. Pairs with the above.
    func carouselBounceToActive()
}

final class BrowseNavController: UIViewController {
    let browseTab: BrowseTab
    private let environment: AppEnvironment
    private let client: NextcloudClient
    private let tabsModel: TabsModel
    private weak var dragHandler: CarouselDragHandling?

    /// The actual navigation stack, hosted as a child so its view-management can't
    /// disturb the floating overlays layered above it.
    private let navController = UINavigationController()

    private let bar = GlassTabBar()
    private var barObservation: ObservationToken?
    private var photoViewer: PhotoViewerController?
    private var viewerObservation: ObservationToken?
    /// True while the Gallery toggle's cross-dissolve is in flight, to ignore repeat
    /// taps until it settles.
    private var isSwappingPresentation = false

    init(tab: BrowseTab, environment: AppEnvironment, client: NextcloudClient, tabsModel: TabsModel, dragHandler: CarouselDragHandling?) {
        self.browseTab = tab
        self.environment = environment
        self.client = client
        self.tabsModel = tabsModel
        self.dragHandler = dragHandler
        super.init(nibName: nil, bundle: nil)

        // Build the VC stack: the Home hub plus one screen per persisted route, each
        // in its stored presentation mode.
        let stack = (0...browseTab.path.count).map { makeViewController(atDepth: $0) }
        navController.setViewControllers(stack, animated: false)
        navController.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Host the nav stack full-bleed; overlays are added above it afterwards.
        addChild(navController)
        navController.view.frame = view.bounds
        navController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navController.view)
        navController.didMove(toParent: self)

        setUpBar()
        // Embed/remove the tab's photo viewer to match its model. As a child of this
        // page (a sibling above the nav stack, not a modal), it rides the carousel and
        // persists per tab.
        viewerObservation = observeChanges { [weak self] in
            guard let self else { return }
            self.syncPhotoViewer(self.browseTab.viewer)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Belt-and-braces: keep the overlays above the nav stack (cheap, and these are
        // genuine siblings now so it won't fight the nav controller).
        view.bringSubviewToFront(bar)
        if let photoViewer { view.bringSubviewToFront(photoViewer.view) }
    }

    // MARK: - Embedded photo viewer

    private func syncPhotoViewer(_ presentation: ViewerPresentation?) {
        if let presentation, photoViewer?.viewerID != presentation.id {
            embedPhotoViewer(presentation)
        } else if presentation == nil, photoViewer != nil {
            removePhotoViewer()
        }
    }

    private func embedPhotoViewer(_ presentation: ViewerPresentation) {
        removePhotoViewer()
        let viewer = PhotoViewerController(
            photos: presentation.photos, initialID: presentation.initialID,
            environment: environment, tabs: tabsModel
        )
        viewer.source = browseTab.viewerSource
        viewer.dragHandler = dragHandler
        viewer.onClose = { [weak self] in
            self?.removePhotoViewer()
            self?.browseTab.viewer = nil
            self?.browseTab.viewerSource = nil
        }
        // Reflect the open photo's name in the tab's title (bar pill + switcher).
        viewer.onCurrentPhotoChanged = { [weak self] photo in
            self?.browseTab.viewerTitle = photo?.fileName
        }
        addChild(viewer)
        viewer.view.frame = view.bounds
        viewer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(viewer.view)
        viewer.didMove(toParent: self)
        photoViewer = viewer
        view.layoutIfNeeded()
        viewer.animateOpen()
    }

    private func removePhotoViewer() {
        guard let viewer = photoViewer else { return }
        photoViewer = nil
        browseTab.viewerTitle = nil   // revert the tab title to the folder name
        viewer.willMove(toParent: nil)
        viewer.view.removeFromSuperview()
        viewer.removeFromParent()
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
        bar.onCloseTab = { [weak self] in guard let self else { return }; tabsModel.closeTab(browseTab.id) }
        bar.onCloseOtherTabs = { [weak self] in guard let self else { return }; tabsModel.closeOtherTabs(keeping: browseTab.id) }
        bar.onNextTab = { [weak self] in self?.tabsModel.selectNext() }
        bar.onPrevTab = { [weak self] in self?.tabsModel.selectPrevious() }
        bar.onDragChanged = { [weak self] tx in self?.dragHandler?.carouselDragChanged(translation: tx) }
        bar.onDragEnded = { [weak self] tx, v in self?.dragHandler?.carouselDragEnded(translation: tx, velocity: v) }
        bar.onParkForSnapshot = { [weak self] in self?.dragHandler?.carouselParkForSnapshot() }
        bar.onBounceToRest = { [weak self] in self?.dragHandler?.carouselBounceToActive() }
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
        // The toggle is live on any folder/gallery screen; it's "active" (filled)
        // while the flattened gallery is the one showing.
        let top = navController.topViewController
        let galleryActive = top is FlatGalleryViewController
        let galleryEnabled = galleryActive || top is FolderGridViewController
        bar.configure(
            title: browseTab.title,
            count: tabsModel.tabs.count,
            isWarming: warming,
            galleryEnabled: galleryEnabled,
            galleryActive: galleryActive,
            canZoomIn: browseTab.zoom.canZoomIn,
            canZoomOut: browseTab.zoom.canZoomOut
        )
    }

    // MARK: - Destinations

    /// The screen at stack `depth`: depth 0 is the always-present Home hub (it has no
    /// route entry — see ``BrowseTab/path``); deeper levels are built from their route.
    private func makeViewController(atDepth depth: Int) -> UIViewController {
        depth <= 0 ? makeHomeViewController() : makeViewController(for: browseTab.path[depth - 1])
    }

    private func makeHomeViewController() -> UIViewController {
        let home = HomeViewController(environment: environment, client: client, navigator: self)
        home.additionalSafeAreaInsets.bottom = GlassTabBar.preferredHeight + 4
        return home
    }

    /// Builds a pushed level's screen, pre-set with the bottom bar's safe-area inset so
    /// content clears the floating bar however the screen arrives — pushed, restored at
    /// launch, or swapped in by the Gallery toggle. Folder levels honour their
    /// browse/flat mode; favorites and albums are always one flat gallery fed by a live
    /// fetch.
    private func makeViewController(for route: BrowseRoute) -> UIViewController {
        let vc: UIViewController
        switch route.kind {
        case .folder:
            switch route.mode {
            case .browse:
                vc = makeFolderGrid(folderPath: route.path, title: route.title, account: route.account)
            case .flat:
                vc = FlatGalleryViewController(folderPath: route.path, title: route.title, account: route.account, environment: environment, client: client, tab: browseTab, navigator: self)
            }
        case .favorites:
            vc = RemoteGalleryViewController(title: route.title, account: route.account, environment: environment, client: client, tab: browseTab, navigator: self) { [client] in
                try await client.favorites()
            }
        case .album:
            let davPath = route.path
            vc = RemoteGalleryViewController(title: route.title, account: route.account, environment: environment, client: client, tab: browseTab, navigator: self) { [client] in
                try await client.albumPhotos(davPath: davPath)
            }
        case .tag:
            let tagId = route.path
            vc = RemoteGalleryViewController(title: route.title, account: route.account, environment: environment, client: client, tab: browseTab, navigator: self) { [client] in
                try await client.taggedFiles(tagId: tagId)
            }
        }
        vc.additionalSafeAreaInsets.bottom = GlassTabBar.preferredHeight + 4
        return vc
    }

    private func makeFolderGrid(folderPath: String, title: String, account: String) -> FolderGridViewController {
        let grid = FolderGridViewController(folderPath: folderPath, title: title, account: account, environment: environment, client: client, tab: browseTab, navigator: self)
        // Content settling can change the bar's state (title/count) → refresh it.
        grid.onContentChanged = { [weak self, weak grid] in
            guard let self, self.navController.topViewController === grid else { return }
            self.updateBarState()
        }
        return grid
    }

    // MARK: - Navigation

    /// Pushes a new level, recording it on the tab so it restores.
    private func push(_ route: BrowseRoute) {
        browseTab.path.append(route)
        tabsModel.save()
        navController.pushViewController(makeViewController(for: route), animated: true)
    }

    /// Toggles the current level between its folder grid and its flattened gallery,
    /// swapping the screen *in place* (same stack depth) rather than pushing — so
    /// tapping Gallery again returns to the previous representation. The mode is
    /// mirrored into the tab's stored state so it persists and the bar/switcher stay
    /// correct.
    private func toggleGallery() {
        guard !isSwappingPresentation else { return }
        let depth = navController.viewControllers.count - 1
        // Home (depth 0) has no toggle; favorites/albums are always flat.
        guard depth >= 1, browseTab.path[depth - 1].kind == .folder else { return }
        browseTab.path[depth - 1].mode.toggle()
        tabsModel.save()
        isSwappingPresentation = true
        swapTopViewController(with: makeViewController(atDepth: depth))
    }

    /// Cross-dissolves the top screen to `newTop` without changing stack depth, so the
    /// back button and the screens beneath are untouched. The floating bar and any
    /// open viewer are siblings of the nav view, so they stay put through the fade.
    private func swapTopViewController(with newTop: UIViewController) {
        var stack = navController.viewControllers
        guard !stack.isEmpty else { isSwappingPresentation = false; return }
        stack[stack.count - 1] = newTop
        UIView.transition(with: navController.view, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.navController.setViewControllers(stack, animated: false)
        } completion: { [weak self] _ in
            self?.isSwappingPresentation = false
            self?.updateBarState()
        }
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
            // A leaf opens straight into its flattened gallery; the Gallery toggle can
            // still flip it to a browse grid.
            let mode: BrowseRoute.Mode = await isLeafFolder(route) ? .flat : .browse
            push(.folder(path: route.folderPath, title: route.title, account: route.account, mode: mode))
        }
    }

    func openFolderInNewTab(_ route: FolderRoute) {
        tabsModel.open(.folder(path: route.folderPath, title: route.title, account: route.account, mode: .browse), inNewTab: true)
    }

    func openFavorites() {
        push(.favorites(account: client.credentials.account))
    }

    func openAlbum(_ album: Album) {
        push(.album(album, account: client.credentials.account))
    }

    func openTag(id: String, name: String) {
        push(.tag(id: id, name: name, account: client.credentials.account))
    }

    func openViewer(photos: [PhotoItem], initialID: String, source: (any PhotoViewerTransitionSource)?) {
        browseTab.openViewer(photos: photos, initialID: initialID, source: source)
    }
}

// MARK: - UINavigationControllerDelegate

extension BrowseNavController: UINavigationControllerDelegate {
    // The bottom-bar safe-area inset is applied per screen in `makeViewController`,
    // which covers every appearance (push, restore, and the in-place toggle swap).

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        // A pop (back button / edge-swipe) leaves fewer VCs than path entries — trim
        // the path so it persists and the switcher title is correct.
        let depth = navigationController.viewControllers.count - 1
        if depth < browseTab.path.count {
            browseTab.path = Array(browseTab.path.prefix(depth))
            tabsModel.save()
        }
        updateBarState()
    }
}
