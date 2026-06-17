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

    /// Called once the viewer has actually dismissed (tapped Done or swiped away),
    /// so the host can clear its presentation state.
    var onDidDismiss: (() -> Void)?

    /// The custom present/dismiss/swipe transition. Set by the presenter (it carries
    /// the grid source); also assigned as the (weak) `transitioningDelegate`, so the
    /// viewer holds the only strong reference. No retain cycle: the controller keeps
    /// only weak references back to the viewer and source.
    var transitionController: PhotoViewerTransitionController?

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
    private let bottomBar = UIToolbar()
    private let bottomScrim = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private var filmstrip: PhotoFilmstripView!

    private var chromeTap: UITapGestureRecognizer!
    private var dismissPan: UIPanGestureRecognizer!
    private var chromeHidden = false
    private var chromeHiddenBeforeDrag = false

    private let selectionHaptic = UISelectionFeedbackGenerator()
    private let dismissHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var thresholdHapticFired = false

    private var saverObservation: ObservationToken?
    private var presentingSaveError = false
    private var didDismiss = false

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

        // Frosted bottom region behind the filmstrip + toolbar.
        bottomScrim.translatesAutoresizingMaskIntoConstraints = false

        let toolbarAppearance = UIToolbarAppearance()
        toolbarAppearance.configureWithTransparentBackground()
        bottomBar.standardAppearance = toolbarAppearance
        bottomBar.compactAppearance = toolbarAppearance
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        let showTabs = UIBarButtonItem(image: UIImage(systemName: "square.on.square"), style: .plain, target: self, action: #selector(showTabsTapped))
        showTabs.accessibilityLabel = "Show Tabs"
        bottomBar.items = [.flexibleSpace(), showTabs, .flexibleSpace()]

        view.addSubview(bottomScrim)
        view.addSubview(bottomBar)
        view.addSubview(topBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
        view.insertSubview(filmstrip, aboveSubview: bottomScrim)

        NSLayoutConstraint.activate([
            filmstrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filmstrip.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            filmstrip.heightAnchor.constraint(equalToConstant: PhotoFilmstripView.preferredHeight),
            bottomScrim.topAnchor.constraint(equalTo: filmstrip.topAnchor),
            bottomScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
        }
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
    }

    // MARK: - Chrome

    @objc private func handleChromeTap() {
        fadeChrome(hidden: !chromeHidden)
    }

    private var chromeViews: [UIView] { [topBar, bottomScrim, filmstrip, bottomBar] }

    /// Sets chrome opacity directly (used inside the transition animation blocks).
    func setChromeAlpha(_ alpha: CGFloat) {
        chromeViews.forEach { $0.alpha = alpha }
    }

    /// Sets chrome visibility without animation (used to restore after a transition).
    func setChromeHidden(_ hidden: Bool) {
        chromeHidden = hidden
        setChromeAlpha(hidden ? 0 : 1)
    }

    private func fadeChrome(hidden: Bool) {
        chromeHidden = hidden
        UIView.animate(withDuration: 0.25) { self.setChromeAlpha(hidden ? 0 : 1) }
    }

    // MARK: - Swipe-down dismiss

    private var dismissDistance: CGFloat { max(1, view.bounds.height * 0.5) }
    private let dismissThreshold: CGFloat = 120

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            guard let transitionController else { return }
            transitionController.isInteractive = true
            thresholdHapticFired = false
            dismissHaptic.prepare()
            chromeHiddenBeforeDrag = chromeHidden
            fadeChrome(hidden: true)
            dismiss(animated: true)

        case .changed:
            let translation = pan.translation(in: view)
            let progress = max(0, min(1, translation.y / dismissDistance))
            transitionController?.activeDriver?.update(progress: progress, translation: translation)
            if !thresholdHapticFired, translation.y > dismissThreshold {
                thresholdHapticFired = true
                dismissHaptic.impactOccurred()
            }

        case .ended, .cancelled, .failed:
            let translation = pan.translation(in: view)
            let velocity = pan.velocity(in: view)
            let shouldDismiss = translation.y > 0 && (translation.y > dismissThreshold || velocity.y > 1000)
            transitionController?.isInteractive = false
            if shouldDismiss {
                transitionController?.activeDriver?.finish()
            } else {
                fadeChrome(hidden: chromeHiddenBeforeDrag)
                transitionController?.activeDriver?.cancel()
            }

        default:
            break
        }
    }

    // MARK: - Transition hooks

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

    func setPageContentHidden(_ hidden: Bool) {
        pageController.view.isHidden = hidden
    }

    /// Called by the dismiss paths once the viewer is actually gone, exactly once.
    func handleDidDismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        onDidDismiss?()
    }

    // MARK: - Save button

    private func updateSaveButton(for status: PhotoSaver.Status) {
        switch status {
        case .saving:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            topItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        case .saved:
            let item = UIBarButtonItem(image: UIImage(systemName: "checkmark.circle.fill"), style: .plain, target: nil, action: nil)
            item.tintColor = .systemGreen
            topItem.rightBarButtonItem = item
        default:
            topItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), style: .plain, target: self, action: #selector(saveTapped))
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

    @objc private func doneTapped() {
        transitionController?.isInteractive = false
        dismiss(animated: true) { [weak self] in self?.handleDidDismiss() }
    }

    @objc private func showTabsTapped() { tabs.openSwitcher() }

    @objc private func saveTapped() {
        guard let photo = currentPhoto else { return }
        Task { await saver.save(photo: photo, client: environment.client, store: environment.fullImageStore) }
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
        // The chrome-toggle tap ignores touches on the bars / filmstrip so their own
        // controls (Done, Save, Show Tabs, filmstrip cells) handle the tap instead.
        guard gestureRecognizer === chromeTap, let touched = touch.view else { return true }
        return !touched.isDescendant(of: topBar)
            && !touched.isDescendant(of: bottomBar)
            && !touched.isDescendant(of: filmstrip)
    }
}
