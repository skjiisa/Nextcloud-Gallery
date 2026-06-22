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

/// Receives a tab bar's drag: a single continuous gesture that scrubs the carousel between
/// tabs as it moves sideways and shrinks the active tab into a switcher card as it moves up,
/// blending the two rather than switching modes.
@MainActor
protocol CarouselDragHandling: AnyObject {
    /// The bar drag moved: `location` (window space), `up` (points above the start) and `side`
    /// (signed sideways travel). The coordinator folds both axes into one live transform —
    /// sideways scrub + upward shrink at once — nothing commits yet.
    func dragChanged(at location: CGPoint, up: CGFloat, side: CGFloat)
    /// The finger let go: the coordinator commits whichever action the release crossed — open
    /// the switcher (clearly up, past the lift threshold) or switch tabs (sideways, past the
    /// carousel threshold) — or settles back. `velocity` is window-space pts/sec.
    func dragEnded(at location: CGPoint, up: CGFloat, side: CGFloat, velocity: CGPoint)
    /// The gesture was cancelled by the system — settle everything, commit nothing.
    func dragCancelled()
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

    /// Whichever bar is currently on screen for this tab — the viewer's while a photo is
    /// open, otherwise the browse bar.
    private var activeBar: GlassTabBar { photoViewer?.liftBar ?? bar }

    /// A snapshot of this tab's content WITHOUT the bar, so the bar is never baked into the
    /// switcher card/cell — it's animated separately instead. The browse bar is a *sibling*
    /// of the nav stack, so rendering the nav stack alone excludes it cleanly; the viewer
    /// renders its own content (its bar lives inside it).
    func contentSnapshot() -> UIImage? {
        if let viewer = photoViewer { return viewer.contentSnapshot() }
        return WindowSnapshot.render(navController.view)
    }

    /// A snapshot of the bar plus its on-screen frame in `space`, used for the fade-out
    /// "ghost" overlaid at lift-off (so the bar dissolves in place rather than vanishing).
    func barGhost(in space: UICoordinateSpace) -> (image: UIImage, frame: CGRect)? {
        guard let image = WindowSnapshot.render(activeBar) else { return nil }
        return (image, activeBar.convert(activeBar.bounds, to: space))
    }

    /// Fades the bar in from hidden (at rest) — used when reopening a tab so the bar appears
    /// smoothly instead of popping in.
    func fadeBarIn() {
        activeBar.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0.05, options: [.allowUserInteraction]) {
            self.activeBar.alpha = 1
        }
    }

    /// A reusable mask that crops this page toward the switcher card's aspect as it lifts. The
    /// tab becomes card-shaped by *cropping* top & bottom (an opaque, rounded window over the
    /// live content) rather than squashing it — so the content stays undistorted, exactly like
    /// the aspect-fill snapshot the switcher cell shows.
    private lazy var liftCropMask: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = UIColor.black.cgColor   // opaque == the visible region
        layer.cornerCurve = .continuous
        return layer
    }()

    /// The page-local rect the crop narrows to at `progress`: full bounds at 0, a centred
    /// switcher-aspect (``TabCardCell/cardAspect``) window at 1.
    private func liftCropRect(progress: CGFloat) -> CGRect {
        let b = view.bounds
        let cardHeight = b.width / TabCardCell.cardAspect
        let height = b.height - (b.height - cardHeight) * min(max(progress, 0), 1)
        return CGRect(x: 0, y: (b.height - height) / 2, width: b.width, height: height)
    }

    /// Crops + rounds this page into its lifted card shape and fades the bar. `progress` is 0 at
    /// full-screen, 1 fully lifted; `scale` is the carousel's live shrink (divided out so the
    /// on-screen corner radius stays constant); `barAlpha` fades the dragged bar away so the
    /// card reads as chrome-free and the commit's bar-less snapshot swaps in without a pop.
    func setLiftProgress(_ progress: CGFloat, scale: CGFloat, barAlpha: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        activeBar.alpha = barAlpha
        guard clamped > 0.001 else { view.layer.mask = nil; return }
        // The mask is a standalone CALayer, so frame/cornerRadius changes would otherwise pick up
        // Core Animation's default 0.25s implicit animation and lag the finger — the crop trailing
        // the container's (instant) UIView scale. Disable actions so the shape tracks the height.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liftCropMask.frame = liftCropRect(progress: clamped)
        liftCropMask.cornerRadius = TabCardCell.cornerRadius * clamped / max(scale, 0.01)
        view.layer.mask = liftCropMask
        CATransaction.commit()
    }

    /// Restores the bar alpha without touching the crop mask — used while the mask is being
    /// animated open separately (see ``animateLiftReset(duration:)``).
    func setBarAlpha(_ alpha: CGFloat) { activeBar.alpha = alpha }

    /// The on-screen frame (in `space`) of this page's cropped card at `progress` — where the
    /// lift's flying snapshot starts, so the hand-off into the switcher is seamless.
    func liftCardFrame(progress: CGFloat, in space: UICoordinateSpace) -> CGRect {
        view.convert(liftCropRect(progress: progress), to: space)
    }

    /// Animates the crop open and drops the mask over `duration` (the carousel's settle). The
    /// mask is a sublayer a `UIView` animation block won't touch, so it's animated by hand; the
    /// caller's enclosing animation restores the bar + page alpha alongside.
    func animateLiftReset(duration: TimeInterval) {
        guard view.layer.mask === liftCropMask else { return }
        let pres = liftCropMask.presentation() ?? liftCropMask
        let fromBounds = pres.bounds, fromPosition = pres.position, fromRadius = pres.cornerRadius
        liftCropMask.frame = liftCropRect(progress: 0)
        liftCropMask.cornerRadius = 0
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(cgRect: fromBounds)
        bounds.toValue = NSValue(cgRect: liftCropMask.bounds)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(cgPoint: fromPosition)
        position.toValue = NSValue(cgPoint: liftCropMask.position)
        let radius = CABasicAnimation(keyPath: "cornerRadius")
        radius.fromValue = fromRadius
        radius.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [bounds, position, radius]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.view.layer.mask === self.liftCropMask else { return }
            self.view.layer.mask = nil
        }
        liftCropMask.add(group, forKey: "liftReset")
        CATransaction.commit()
    }
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
        bar.onDrag = { [weak self] loc, up, side in self?.dragHandler?.dragChanged(at: loc, up: up, side: side) }
        bar.onDragRelease = { [weak self] loc, up, side, v in self?.dragHandler?.dragEnded(at: loc, up: up, side: side, velocity: v) }
        bar.onDragCancel = { [weak self] in self?.dragHandler?.dragCancelled() }
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
        case .allAlbums:
            vc = AllAlbumsViewController(environment: environment, client: client, navigator: self)
        case .allTags:
            vc = AllTagsViewController(environment: environment, client: client, navigator: self)
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
    func openFolder(_ route: FolderRoute, mode: BrowseRoute.Mode?) {
        if let mode {
            push(.folder(path: route.folderPath, title: route.title, account: route.account, mode: mode))
            return
        }
        Task {
            // No explicit mode: a leaf opens straight into its flattened gallery; the
            // Gallery toggle can still flip it to a browse grid.
            let resolved: BrowseRoute.Mode = await isLeafFolder(route) ? .flat : .browse
            push(.folder(path: route.folderPath, title: route.title, account: route.account, mode: resolved))
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

    func openAllAlbums() {
        push(.allAlbums(account: client.credentials.account))
    }

    func openAllTags() {
        push(.allTags(account: client.credentials.account))
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
