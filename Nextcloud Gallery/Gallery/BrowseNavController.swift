//
//  BrowseNavController.swift
//  Nextcloud Gallery
//
//  One tab's page. Hosts a child ``UINavigationController`` (rooted at the Files-root
//  folder grid) with the tab's Liquid Glass bottom bar — and, when a photo is open,
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
    /// Abandon an in-flight drag and re-center the active tab *immediately*, with no
    /// snap animation — used when a drag resolves to opening the switcher, so the live
    /// screen is at rest before its card snapshot is captured.
    func carouselDragCancelled()
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

        // Build the VC stack: one screen per level (Files-root + each persisted
        // route), each in its stored presentation mode.
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
        bar.onDragCancelled = { [weak self] in self?.dragHandler?.carouselDragCancelled() }
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

    /// The folder shown at stack `depth` (0 == the Files-root "Photos" level), with
    /// its current presentation mode. The root has no route entry, so its mode lives
    /// on the tab; deeper levels carry their own.
    private func location(atDepth depth: Int) -> (folderPath: String, title: String, account: String, mode: BrowseRoute.Mode) {
        if depth <= 0 {
            return (client.filesRootPath, "Photos", client.credentials.account, browseTab.rootMode)
        }
        let route = browseTab.path[depth - 1]
        return (route.folderPath, route.title, route.account, route.mode)
    }

    private func makeViewController(atDepth depth: Int) -> UIViewController {
        let l = location(atDepth: depth)
        return makeViewController(folderPath: l.folderPath, title: l.title, account: l.account, mode: l.mode)
    }

    /// Builds a folder's screen in the given presentation mode, pre-set with the
    /// bottom bar's safe-area inset so content clears the floating bar however the
    /// screen arrives — pushed, restored at launch, or swapped in by the toggle.
    private func makeViewController(folderPath: String, title: String, account: String, mode: BrowseRoute.Mode) -> UIViewController {
        let vc: UIViewController
        switch mode {
        case .browse:
            vc = makeFolderGrid(folderPath: folderPath, title: title, account: account)
        case .flat:
            vc = FlatGalleryViewController(folderPath: folderPath, title: title, account: account, environment: environment, client: client, tab: browseTab, navigator: self)
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

    /// Pushes a new folder level in `mode`, recording it on the tab so it restores.
    private func push(folderPath: String, title: String, account: String, mode: BrowseRoute.Mode) {
        browseTab.path.append(BrowseRoute(folderPath: folderPath, title: title, account: account, mode: mode))
        tabsModel.save()
        navController.pushViewController(makeViewController(folderPath: folderPath, title: title, account: account, mode: mode), animated: true)
    }

    /// Toggles the current level between its folder grid and its flattened gallery,
    /// swapping the screen *in place* (same stack depth) rather than pushing — so
    /// tapping Gallery again returns to the previous representation. The mode is
    /// mirrored into the tab's stored state so it persists and the bar/switcher stay
    /// correct.
    private func toggleGallery() {
        guard !isSwappingPresentation else { return }
        let depth = navController.viewControllers.count - 1
        guard depth >= 0 else { return }
        if depth == 0 {
            browseTab.rootMode.toggle()
        } else {
            browseTab.path[depth - 1].mode.toggle()
        }
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
            push(folderPath: route.folderPath, title: route.title, account: route.account, mode: mode)
        }
    }

    func openFolderInNewTab(_ route: FolderRoute) {
        tabsModel.open(BrowseRoute(folderPath: route.folderPath, title: route.title, account: route.account, mode: .browse), inNewTab: true)
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
