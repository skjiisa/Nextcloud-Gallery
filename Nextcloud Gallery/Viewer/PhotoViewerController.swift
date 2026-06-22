//
//  PhotoViewerController.swift
//  Nextcloud Gallery
//
//  Full-screen, swipeable photo viewer with zoom and save-to-Photos, built on
//  UIPageViewController. It feels like the native Photos viewer: the tapped tile
//  grows into the photo (see ``PhotoViewerTransitioning``), a swipe down shrinks it
//  back interactively, a bottom filmstrip (``PhotoFilmstripView``) scrubs between
//  photos, and a tap hides the chrome. The background matches the light/dark theme.
//
//  Horizontal paging is disabled while a page is zoomed. Presented over a tab; the
//  open photo lives on ``BrowseTab/viewer`` so it survives switching tabs (see
//  ``RootCarouselViewController``).
//

import UIKit

final class PhotoViewerController: UIViewController {
    /// Identifies which presentation this viewer is showing (matches
    /// ``ViewerPresentation/id``), so the carousel can tell when to re-present.
    let viewerID: String

    /// Called after the close / swipe-away animation finishes, so the host (the tab's
    /// nav controller) removes this child viewer and clears ``BrowseTab/viewer``.
    var onClose: (() -> Void)?

    /// Called when the shown photo changes (on open and each page turn) so the host can
    /// reflect the image's name in the tab's title.
    var onCurrentPhotoChanged: ((PhotoItem?) -> Void)?

    /// The grid the photo grew from — supplies the tile geometry for the grow / shrink
    /// / swipe hero. Weak; owned by the tab's navigation stack.
    weak var source: (any PhotoViewerTransitionSource)?

    /// The carousel, so the bar's horizontal drag can switch tabs while a photo is
    /// open (set by the host). Weak — the carousel outlives us.
    weak var dragHandler: CarouselDragHandling?

    private let photos: [PhotoItem]
    private let environment: AppEnvironment
    private let tabs: TabsModel
    private let saver = PhotoSaver()

    private var currentIndex: Int
    private var pageController: UIPageViewController!
    private weak var pagingScrollView: UIScrollView?

    /// Theme-matched backdrop behind the photo; faded by the transitions to reveal
    /// the grid during the grow-open / swipe-dismiss.
    let backdropView = UIView()

    private let topBar = UINavigationBar()
    private let topItem = UINavigationItem()
    /// Right-bar action items. Save morphs (icon → spinner → check); the favorite heart
    /// and the "more" menu (Add to Album / Tags) sit to its left and stay put.
    private var saveItem: UIBarButtonItem!
    private var favoriteItem: UIBarButtonItem!
    private var moreItem: UIBarButtonItem!
    /// The shown photo's fetched favorite + tags (nil while loading); drives the heart.
    /// Refreshed on every page change.
    private var currentMetadata: PhotoMetadata?
    private var metadataTask: Task<Void, Never>?
    /// The app's bottom tab bar, shown over the viewer (viewer mode: just the tab
    /// pill → switcher, New tab, Settings). Keeps tab context while viewing a photo.
    private let tabBar = GlassTabBar()
    /// The viewer's bottom bar, exposed so the tab page can animate it for the switcher
    /// transition (it's overlaid live rather than baked into the snapshot).
    var liftBar: GlassTabBar { tabBar }

    /// A snapshot of the photo WITHOUT the bottom tab bar, for the switcher card/cell. The
    /// bar is a child of this view, so it's hidden during the render (`afterScreenUpdates`
    /// must be true for the hide to take effect).
    func contentSnapshot() -> UIImage? {
        let wasHidden = tabBar.isHidden
        tabBar.isHidden = true
        defer { tabBar.isHidden = wasHidden }
        return WindowSnapshot.render(view, afterScreenUpdates: true)
    }
    private var filmstrip: PhotoFilmstripView!
    private var barObservation: ObservationToken?

    private var chromeTap: UITapGestureRecognizer!
    private var dismissPan: UIPanGestureRecognizer!
    private var chromeHidden = false
    private var chromeHiddenBeforeDrag = false

    private let selectionHaptic = UISelectionFeedbackGenerator()
    private let dismissHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var thresholdHapticFired = false

    private var saverObservation: ObservationToken?
    private var presentingSaveError = false

    // Interactive swipe-down hero state.
    private var swipeHero: UIImageView?
    private var swipeStartFrame: CGRect = .zero
    private var swipePhotoID = ""

    init(photos: [PhotoItem], initialID: String, environment: AppEnvironment, tabs: TabsModel) {
        self.photos = photos
        self.environment = environment
        self.tabs = tabs
        self.viewerID = initialID
        self.currentIndex = max(0, photos.firstIndex { $0.id == initialID } ?? 0)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear so the grid shows through while opening/dismissing; the backdrop
        // supplies the theme colour at rest.
        view.backgroundColor = .clear

        // Gestures first (so the pager setup can require the chrome tap to yield to
        // double-tap zoom), then the pager (below the chrome), then the chrome on top.
        setUpBackdrop()
        setUpGestures()
        setUpPageController()
        setUpChrome()
        setUpFilmstrip()
        updateTitle()

        saverObservation = observeChanges { [weak self] in
            guard let self else { return }
            self.updateSaveButton(for: self.saver.status)
            self.presentSaveErrorIfNeeded()
        }
        barObservation = observeChanges { [weak self] in self?.configureTabBar() }
    }

    // MARK: - Setup

    private func setUpBackdrop() {
        backdropView.backgroundColor = .systemBackground
        backdropView.frame = view.bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdropView)
    }

    private func setUpPageController() {
        pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 0])
        pageController.dataSource = self
        pageController.delegate = self
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageController.view.backgroundColor = .clear
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)

        // Cache the internal paging scroll view so zoom can disable paging.
        pagingScrollView = pageController.view.subviews.compactMap { $0 as? UIScrollView }.first

        if let first = photos.indices.contains(currentIndex) ? makePage(at: currentIndex) : nil {
            pageController.setViewControllers([first], direction: .forward, animated: false)
            yieldChromeTap(to: first)
        }
    }

    private func setUpChrome() {
        let barAppearance = UINavigationBarAppearance()
        barAppearance.configureWithDefaultBackground()
        topBar.standardAppearance = barAppearance
        topBar.scrollEdgeAppearance = barAppearance
        topBar.compactAppearance = barAppearance
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        topBar.items = [topItem]

        favoriteItem = UIBarButtonItem(image: UIImage(systemName: "star"), style: .plain, target: self, action: #selector(favoriteTapped))
        moreItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeMoreMenu())

        // The app's tab bar. All buttons stay in place (zoom + gallery are disabled
        // via `configure` since there's no grid here — they don't shift), and all
        // gestures stay live: tap/up-drag the pill → switcher, horizontal drag →
        // carousel, so you can switch tabs with a photo open.
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onShowTabs = { [weak self] in self?.tabs.openSwitcher() }
        tabBar.onNewTab = { [weak self] in self?.tabs.newTab() }
        tabBar.onSettings = { [weak self] in self?.tabs.isShowingSettings = true }
        // The viewer is always the active tab's, so its tab actions target that tab.
        tabBar.onCloseTab = { [weak self] in guard let self else { return }; tabs.closeTab(tabs.activeTabID) }
        tabBar.onCloseOtherTabs = { [weak self] in guard let self else { return }; tabs.closeOtherTabs(keeping: tabs.activeTabID) }
        tabBar.onNextTab = { [weak self] in self?.tabs.selectNext() }
        tabBar.onPrevTab = { [weak self] in self?.tabs.selectPrevious() }
        tabBar.onLockToggle = { [weak self] in self?.toggleZoomLock() }
        tabBar.onDrag = { [weak self] loc, up, side in self?.dragHandler?.dragChanged(at: loc, up: up, side: side) }
        tabBar.onDragRelease = { [weak self] loc, up, side, v in self?.dragHandler?.dragEnded(at: loc, up: up, side: side, velocity: v) }
        tabBar.onDragCancel = { [weak self] in self?.dragHandler?.dragCancelled() }

        view.addSubview(tabBar)
        view.addSubview(topBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            tabBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            tabBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            tabBar.heightAnchor.constraint(equalToConstant: GlassTabBar.preferredHeight),
        ])
        updateSaveButton(for: saver.status)
    }

    private func setUpFilmstrip() {
        filmstrip = PhotoFilmstripView(
            photos: photos, initialIndex: currentIndex,
            store: environment.thumbnailStore, client: environment.client
        )
        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        filmstrip.onIndexChanged = { [weak self] index in self?.goToPage(index, fromFilmstrip: true) }
        // No backdrop behind the strip — it sits directly over the photo so a tall
        // portrait shows through beneath it. Kept below the tab bar in z-order.
        view.insertSubview(filmstrip, belowSubview: tabBar)

        NSLayoutConstraint.activate([
            filmstrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filmstrip.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -4),
            filmstrip.heightAnchor.constraint(equalToConstant: PhotoFilmstripView.preferredHeight),
        ])
    }

    private func setUpGestures() {
        chromeTap = UITapGestureRecognizer(target: self, action: #selector(handleChromeTap))
        chromeTap.delegate = self
        view.addGestureRecognizer(chromeTap)

        dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        view.addGestureRecognizer(dismissPan)
    }

    // MARK: - Pages

    private func makePage(at index: Int) -> PhotoPageViewController? {
        guard photos.indices.contains(index) else { return nil }
        let page = PhotoPageViewController(photo: photos[index], environment: environment)
        page.onZoomChanged = { [weak self] zoomed in
            self?.pagingScrollView?.isScrollEnabled = !zoomed
            // Zooming in/out flips whether there's a zoom to lock — refresh the button.
            self?.configureTabBar()
        }
        page.onImageChanged = { [weak self] image in self?.onCurrentImageUpgrade?(image) }
        return page
    }

    private func index(of viewController: UIViewController) -> Int? {
        guard let page = viewController as? PhotoPageViewController else { return nil }
        return photos.firstIndex { $0.id == page.photo.id }
    }

    private var currentPhoto: PhotoItem? {
        photos.indices.contains(currentIndex) ? photos[currentIndex] : nil
    }

    private var currentPageVC: PhotoPageViewController? {
        pageController.viewControllers?.first as? PhotoPageViewController
    }

    /// Jumps the pager to `index`. When the filmstrip drove it, the strip already
    /// centered itself, so we don't echo back to it.
    private func goToPage(_ index: Int, fromFilmstrip: Bool) {
        guard photos.indices.contains(index), index != currentIndex, let page = makePage(at: index) else { return }
        let direction: UIPageViewController.NavigationDirection = index > currentIndex ? .forward : .reverse
        currentIndex = index
        pageController.setViewControllers([page], direction: direction, animated: false)
        yieldChromeTap(to: page)
        updateTitle()
        selectionHaptic.selectionChanged()
        if !fromFilmstrip { filmstrip.select(index: index, animated: true) }
    }

    /// The single tap (toggle chrome) must lose to a page's double-tap-to-zoom.
    private func yieldChromeTap(to page: PhotoPageViewController) {
        chromeTap.require(toFail: page.zoomDoubleTap)
    }

    private func updateTitle() {
        topItem.title = currentPhoto?.fileName
        onCurrentPhotoChanged?(currentPhoto)
        configureTabBar()
        loadMetadata()
    }

    /// The viewer's tab bar reflects the *current image's* name (not the active tab's
    /// title), so it reads correctly even while another tab slides in over it, and so
    /// the tab title follows the open photo. Count + warming come from the model.
    private func configureTabBar() {
        let warming = environment.warmingCoordinator?.state == .warming
        // The lock button replaces the gallery button here: it's lit when the photo's
        // zoom is locked, and only tappable once there's a zoom worth locking (or a
        // lock to clear).
        let locked = currentPhoto.map { environment.zoomLockStore.isLocked($0.id) } ?? false
        let zoomed = currentPageVC?.isZoomed ?? false
        tabBar.configure(
            title: currentPhoto?.fileName ?? "", count: tabs.tabs.count, isWarming: warming,
            galleryEnabled: false, galleryActive: false, canZoomIn: false, canZoomOut: false,
            lockVisible: true, lockEnabled: zoomed || locked, lockActive: locked
        )
    }

    /// Locks the current photo's zoom + pan so it reopens reframed, or clears that lock
    /// if it's already set. Locking needs a zoomed-in photo (the button is disabled at
    /// fit scale); reopening the photo restores it (see ``PhotoPageViewController``).
    private func toggleZoomLock() {
        guard let photo = currentPhoto else { return }
        let store = environment.zoomLockStore
        if store.isLocked(photo.id) {
            store.removeLock(for: photo.id)
            currentPageVC?.clearLock()
        } else if let lock = currentPageVC?.currentLock {
            store.setLock(lock, for: photo.id)
            // Adopt it live so the current zoom immediately becomes the new baseline.
            currentPageVC?.applyLock(lock)
        }
        selectionHaptic.selectionChanged()
        configureTabBar()
    }

    // MARK: - Chrome

    @objc private func handleChromeTap() {
        fadeChrome(hidden: !chromeHidden)
    }

    /// Viewer-level chrome (the Done/Save bar + filmstrip) — faded by the open / close
    /// / swipe transitions. The tab bar is deliberately excluded: it's the tab's
    /// persistent chrome and stays visible over the photo (and through a swipe-to-
    /// dismiss); only the tap-to-hide toggle hides it (see ``toggleChromeViews``).
    private var transitionChromeViews: [UIView] { [topBar, filmstrip] }

    /// Everything the tap-to-hide toggle shows/hides — includes the tab bar.
    private var toggleChromeViews: [UIView] { [topBar, filmstrip, tabBar] }

    /// Sets the viewer chrome opacity directly (used inside the transition animation
    /// blocks). Leaves the tab bar untouched so it stays put over the content.
    func setChromeAlpha(_ alpha: CGFloat) {
        transitionChromeViews.forEach { $0.alpha = alpha }
    }

    private func fadeChrome(hidden: Bool) {
        chromeHidden = hidden
        UIView.animate(withDuration: 0.25) {
            self.toggleChromeViews.forEach { $0.alpha = hidden ? 0 : 1 }
        }
    }

    // MARK: - Open / close / swipe (self-driven hero)

    private var dismissDistance: CGFloat { max(1, view.bounds.height * 0.5) }
    private let dismissThreshold: CGFloat = 120

    /// Grows the photo out of its source tile. Called by the host once the viewer's
    /// view is in the hierarchy. Falls back to a cross-fade when there's no tile.
    func animateOpen() {
        let id = currentPhotoID
        let heroImage = source?.viewerSourceImage(forPhotoID: id) ?? currentDisplayedImage
        let sourceFrame = source?.viewerSourceFrame(forPhotoID: id, in: view)
        let aspect = heroImage.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 } ?? currentAspectRatio
        // A locked photo grows straight to its locked framing (not fit-then-pop): the
        // hero lands on the same zoomed crop the restored page settles to underneath.
        let fitFrame = fittedRect(forAspectRatio: aspect)
        let endFrame = environment.zoomLockStore.lock(for: id).map { lockedDisplayRect(fit: fitFrame, lock: $0) } ?? fitFrame

        backdropView.alpha = 0
        setChromeAlpha(0)

        guard let sourceFrame, let heroImage else {
            backdropView.alpha = 1
            view.alpha = 0
            UIView.animate(withDuration: 0.42) { self.view.alpha = 1; self.setChromeAlpha(1) }
            return
        }

        setPageContentHidden(true)
        source?.setViewerSourceHidden(true, forPhotoID: id)
        let hero = PhotoHero.makeHeroView(image: heroImage)
        hero.frame = sourceFrame
        hero.layer.cornerRadius = PhotoHero.tileCornerRadius
        insertTransitionHero(hero)
        // Sharpen the hero as the page's loader yields preview/full stages.
        onCurrentImageUpgrade = { [weak hero] image in hero?.image = image }

        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.curveEaseOut]) {
            hero.frame = endFrame
            hero.layer.cornerRadius = 0
            self.backdropView.alpha = 1
            self.setChromeAlpha(1)
        } completion: { _ in
            self.onCurrentImageUpgrade = nil
            hero.removeFromSuperview()
            // Make sure the page has settled to its (possibly locked) framing before it
            // shows, so it matches the hero's final frame instead of popping into place.
            self.currentPageVC?.view.layoutIfNeeded()
            self.setPageContentHidden(false)
            self.source?.setViewerSourceHidden(false, forPhotoID: id)
        }
    }

    /// Shrinks the photo back into its tile, then asks the host to remove us.
    private func animateClose() {
        let id = currentPhotoID
        let heroImage = currentDisplayedImage ?? source?.viewerSourceImage(forPhotoID: id)
        let startFrame = currentImageOnScreenRect ?? fittedRect(forAspectRatio: currentAspectRatio)
        let destFrame = source?.viewerSourceFrame(forPhotoID: id, in: view)

        guard let heroImage else {
            UIView.animate(withDuration: 0.32, animations: { self.view.alpha = 0 }, completion: { _ in self.onClose?() })
            return
        }
        setPageContentHidden(true)
        source?.setViewerSourceHidden(true, forPhotoID: id)
        let hero = PhotoHero.makeHeroView(image: heroImage)
        hero.frame = startFrame
        insertTransitionHero(hero)

        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseInOut]) {
            if let destFrame {
                hero.frame = destFrame
                hero.layer.cornerRadius = PhotoHero.tileCornerRadius
            } else {
                hero.alpha = 0
                hero.frame = startFrame.insetBy(dx: startFrame.width * 0.2, dy: startFrame.height * 0.2)
                    .offsetBy(dx: 0, dy: startFrame.height * 0.3)
            }
            self.backdropView.alpha = 0
            self.setChromeAlpha(0)
        } completion: { _ in
            hero.removeFromSuperview()
            self.source?.setViewerSourceHidden(false, forPhotoID: id)
            self.onClose?()
        }
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            // Freeze horizontal paging so a diagonal drag is a pure dismissal.
            pagingScrollView?.isScrollEnabled = false
            thresholdHapticFired = false
            dismissHaptic.prepare()
            chromeHiddenBeforeDrag = chromeHidden
            beginSwipe()

        case .changed:
            let translation = pan.translation(in: view)
            updateSwipe(translation: translation)
            if !thresholdHapticFired, translation.y > dismissThreshold {
                thresholdHapticFired = true
                dismissHaptic.impactOccurred()
            }

        case .ended, .cancelled, .failed:
            pagingScrollView?.isScrollEnabled = true
            let translation = pan.translation(in: view)
            let velocity = pan.velocity(in: view)
            let shouldDismiss = translation.y > 0 && (translation.y > dismissThreshold || velocity.y > 1000)
            if shouldDismiss { finishSwipe(velocity: velocity) } else { cancelSwipe() }

        default:
            break
        }
    }

    private func beginSwipe() {
        swipePhotoID = currentPhotoID
        swipeStartFrame = currentImageOnScreenRect ?? fittedRect(forAspectRatio: currentAspectRatio)
        let hero = PhotoHero.makeHeroView(image: currentDisplayedImage ?? source?.viewerSourceImage(forPhotoID: swipePhotoID))
        hero.frame = swipeStartFrame
        insertTransitionHero(hero)
        swipeHero = hero
        setPageContentHidden(true)
        source?.setViewerSourceHidden(true, forPhotoID: swipePhotoID)
        // Fade the viewer chrome (Done bar + filmstrip) but keep the tab bar visible —
        // it stays over the dismissing photo as the tab's persistent chrome.
        UIView.animate(withDuration: 0.25) { self.setChromeAlpha(0) }
    }

    private func updateSwipe(translation: CGPoint) {
        guard let hero = swipeHero else { return }
        let progress = max(0, min(1, translation.y / dismissDistance))
        let scale = max(0.5, 1 - progress * 0.5)
        let size = CGSize(width: swipeStartFrame.width * scale, height: swipeStartFrame.height * scale)
        let center = CGPoint(x: swipeStartFrame.midX + translation.x, y: swipeStartFrame.midY + translation.y)
        hero.frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        backdropView.alpha = max(0, 1 - progress)
    }

    private func finishSwipe(velocity: CGPoint) {
        guard let hero = swipeHero else { onClose?(); return }
        swipeHero = nil
        let destFrame = source?.viewerSourceFrame(forPhotoID: swipePhotoID, in: view)
        source?.setViewerSourceHidden(true, forPhotoID: swipePhotoID)
        let distance = destFrame.map { abs($0.midY - hero.frame.midY) } ?? 1
        let springVelocity = min(1.5, abs(velocity.y) / max(1, distance))

        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: springVelocity, options: [.curveEaseOut, .allowUserInteraction]) {
            if let destFrame {
                hero.frame = destFrame
                hero.layer.cornerRadius = PhotoHero.tileCornerRadius
            } else {
                hero.alpha = 0
                hero.frame = hero.frame.insetBy(dx: hero.frame.width * 0.15, dy: hero.frame.height * 0.15).offsetBy(dx: 0, dy: 80)
            }
            self.backdropView.alpha = 0
        } completion: { _ in
            hero.removeFromSuperview()
            self.source?.setViewerSourceHidden(false, forPhotoID: self.swipePhotoID)
            self.onClose?()
        }
    }

    private func cancelSwipe() {
        guard let hero = swipeHero else { return }
        swipeHero = nil
        fadeChrome(hidden: chromeHiddenBeforeDrag)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3, options: [.curveEaseOut]) {
            hero.frame = self.swipeStartFrame
            hero.layer.cornerRadius = 0
            self.backdropView.alpha = 1
        } completion: { _ in
            hero.removeFromSuperview()
            self.setPageContentHidden(false)
            self.source?.setViewerSourceHidden(false, forPhotoID: self.swipePhotoID)
        }
    }

    // MARK: - Transition hooks

    /// Set by the open animator to receive the current page's sharper image stages
    /// (preview → full) so the grow hero can upgrade from the grid thumbnail.
    var onCurrentImageUpgrade: ((UIImage) -> Void)?

    var currentPhotoID: String { currentPhoto?.id ?? viewerID }
    var currentPhotoItem: PhotoItem? { currentPhoto }
    var currentDisplayedImage: UIImage? { currentPageVC?.displayedImage }
    var currentImageOnScreenRect: CGRect? { currentPageVC?.displayedImageRect(in: view) }

    var currentAspectRatio: CGFloat {
        if let image = currentDisplayedImage, image.size.height > 0 {
            return image.size.width / image.size.height
        }
        return currentPhoto?.aspectRatio ?? 1
    }

    /// The aspect-fit rect for `aspect` within the full viewer bounds — where the
    /// photo sits on screen, and the end frame of the grow-open animation.
    func fittedRect(forAspectRatio aspect: CGFloat) -> CGRect {
        let bounds = view.bounds
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        var width = bounds.width
        var height = width / aspect
        if height > bounds.height {
            height = bounds.height
            width = height * aspect
        }
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// Where the full image sits on screen at a locked zoom: the fit rect scaled by the
    /// lock's scale and shifted by its pan, so the viewport crops to the locked framing.
    /// (Inverse of `ZoomableImageScrollView`'s scale + content-offset.)
    private func lockedDisplayRect(fit: CGRect, lock: ZoomLock) -> CGRect {
        CGRect(x: fit.minX * lock.scale - lock.offset.x,
               y: fit.minY * lock.scale - lock.offset.y,
               width: fit.width * lock.scale, height: fit.height * lock.scale)
    }

    func setPageContentHidden(_ hidden: Bool) {
        pageController.view.isHidden = hidden
    }

    /// Inserts the transition hero just above the photo and beneath all chrome, so a
    /// tall photo grows/shrinks *behind* the bars and filmstrip instead of over them.
    /// The viewer's view fills the transition container, so frames computed in the
    /// container's space map 1:1 into here.
    func insertTransitionHero(_ heroView: UIView) {
        view.insertSubview(heroView, aboveSubview: pageController.view)
    }

    // MARK: - Save button

    private func updateSaveButton(for status: PhotoSaver.Status) {
        switch status {
        case .saving:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            saveItem = UIBarButtonItem(customView: spinner)
        case .saved:
            let item = UIBarButtonItem(image: UIImage(systemName: "checkmark.circle.fill"), style: .plain, target: nil, action: nil)
            item.tintColor = .systemGreen
            saveItem = item
        default:
            saveItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), style: .plain, target: self, action: #selector(saveTapped))
        }
        refreshRightBarItems()
    }

    /// `rightBarButtonItems[0]` is the rightmost, so this lays out (left→right) the
    /// favorite heart, the "more" menu, then the morphing Save button.
    private func refreshRightBarItems() {
        topItem.rightBarButtonItems = [saveItem, moreItem, favoriteItem].compactMap { $0 }
    }

    private func makeMoreMenu() -> UIMenu {
        let album = UIAction(title: "Add to Album", image: UIImage(systemName: "rectangle.stack.badge.plus")) { [weak self] _ in
            self?.presentAlbumPicker()
        }
        let tags = UIAction(title: "Tags", image: UIImage(systemName: "tag")) { [weak self] _ in
            self?.presentTagPicker()
        }
        return UIMenu(children: [album, tags])
    }

    /// Updates the star to match the shown photo's favorite state.
    private func refreshFavoriteButton() {
        let isFavorite = currentMetadata?.isFavorite ?? false
        favoriteItem?.image = UIImage(systemName: isFavorite ? "star.fill" : "star")
        favoriteItem?.tintColor = isFavorite ? .systemYellow : nil
    }

    /// Fetches the shown photo's favorite + tags so the heart reflects real state.
    /// Cancels any previous fetch; ignores a result if the user has paged on.
    private func loadMetadata() {
        metadataTask?.cancel()
        currentMetadata = nil
        refreshFavoriteButton()
        guard let photo = currentPhoto, let client = environment.client else { return }
        let path = photo.serverPath
        metadataTask = Task { [weak self] in
            let meta = try? await client.fileMetadata(serverPath: path)
            guard let self, !Task.isCancelled, self.currentPhoto?.serverPath == path else { return }
            self.currentMetadata = meta
            self.refreshFavoriteButton()
        }
    }

    private func presentSaveErrorIfNeeded() {
        guard let message = saver.errorMessage, !presentingSaveError else { return }
        presentingSaveError = true
        let alert = UIAlertController(title: "Couldn't Save Photo", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.presentingSaveError = false
            self?.saver.reset()
        })
        present(alert, animated: true)
    }

    // MARK: - Actions

    @objc private func doneTapped() { animateClose() }

    @objc private func saveTapped() {
        guard let photo = currentPhoto else { return }
        Task { await saver.save(photo: photo, client: environment.client, store: environment.fullImageStore) }
    }

    /// Toggles the shown photo's favorite state, optimistically (revert on failure).
    @objc private func favoriteTapped() {
        guard let photo = currentPhoto, let client = environment.client else { return }
        let newValue = !(currentMetadata?.isFavorite ?? false)
        let fileId = currentMetadata?.fileId ?? photo.fileId
        let tags = currentMetadata?.tags ?? []
        currentMetadata = PhotoMetadata(fileId: fileId, isFavorite: newValue, tags: tags)
        refreshFavoriteButton()
        selectionHaptic.selectionChanged()
        let path = photo.serverPath
        Task { [weak self] in
            do {
                try await client.setFavorite(serverPath: path, favorite: newValue)
            } catch {
                guard let self, self.currentPhoto?.serverPath == path else { return }
                self.currentMetadata = PhotoMetadata(fileId: fileId, isFavorite: !newValue, tags: tags)
                self.refreshFavoriteButton()
                self.presentActionError("Couldn't Update Favorite", error)
            }
        }
    }

    private func presentAlbumPicker() {
        guard let photo = currentPhoto, let client = environment.client else { return }
        presentSheet(AlbumPickerViewController(photo: photo, client: client))
    }

    private func presentTagPicker() {
        guard let photo = currentPhoto, let client = environment.client else { return }
        presentSheet(TagPickerViewController(photo: photo, client: client))
    }

    private func presentSheet(_ root: UIViewController) {
        let nav = UINavigationController(rootViewController: root)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func presentActionError(_ title: String, _ error: Error) {
        let message = (error as? GalleryError)?.userMessage ?? error.localizedDescription
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - Paging

extension PhotoViewerController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = index(of: viewController), index > 0 else { return nil }
        return makePage(at: index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = index(of: viewController), index < photos.count - 1 else { return nil }
        return makePage(at: index + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let current = pageController.viewControllers?.first, let index = index(of: current) else { return }
        currentIndex = index
        yieldChromeTap(to: current as! PhotoPageViewController)
        updateTitle()
        filmstrip.select(index: index, animated: true)
        selectionHaptic.selectionChanged()
    }
}

// MARK: - Gestures

extension PhotoViewerController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        // Swipe-to-dismiss only when not zoomed, and only for a downward-dominant drag
        // (horizontal swipes belong to the pager; upward/zoomed drags pan the photo).
        if currentPageVC?.isZoomed == true { return false }
        let velocity = dismissPan.velocity(in: view)
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Let the dismiss pan coexist with the page/scroll view pans; the gating above
        // keeps it from firing on horizontal swipes.
        gestureRecognizer === dismissPan || other === dismissPan
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The chrome-toggle tap AND the swipe-dismiss ignore touches on the bars /
        // filmstrip, so their own controls handle them — and crucially so dragging the
        // tab bar drives only the carousel, not the viewer's swipe-dismiss.
        guard gestureRecognizer === chromeTap || gestureRecognizer === dismissPan,
              let touched = touch.view else { return true }
        return !touched.isDescendant(of: topBar)
            && !touched.isDescendant(of: tabBar)
            && !touched.isDescendant(of: filmstrip)
    }
}
