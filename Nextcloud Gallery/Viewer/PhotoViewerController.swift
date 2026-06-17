//
//  PhotoViewerController.swift
//  Nextcloud Gallery
//
//  Full-screen, swipeable photo viewer with zoom and save-to-Photos, built on
//  UIPageViewController. Horizontal paging is disabled while a page is zoomed.
//  Presented over a tab; the open photo lives on ``BrowseTab/viewer`` so it
//  survives switching tabs (see ``RootCarouselViewController``).
//

import UIKit

final class PhotoViewerController: UIViewController {
    /// Identifies which presentation this viewer is showing (matches
    /// ``ViewerPresentation/id``), so the carousel can tell when to re-present.
    let viewerID: String

    /// Called when the user taps Done — clears the tab's viewer state.
    var onClose: (() -> Void)?

    private let photos: [PhotoItem]
    private let environment: AppEnvironment
    private let tabs: TabsModel
    private let saver = PhotoSaver()

    private var currentIndex: Int
    private var pageController: UIPageViewController!
    private weak var pagingScrollView: UIScrollView?

    private let topBar = UINavigationBar()
    private let topItem = UINavigationItem()
    private let bottomBar = UIToolbar()

    private var saverObservation: ObservationToken?
    private var presentingSaveError = false

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
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        setUpPageController()
        setUpChrome()
        updateTitle()

        saverObservation = observeChanges { [weak self] in
            guard let self else { return }
            self.updateSaveButton(for: self.saver.status)
            self.presentSaveErrorIfNeeded()
        }
    }

    // MARK: - Setup

    private func setUpPageController() {
        pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 0])
        pageController.dataSource = self
        pageController.delegate = self
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)

        // Cache the internal paging scroll view so zoom can disable paging.
        pagingScrollView = pageController.view.subviews.compactMap { $0 as? UIScrollView }.first

        if let first = photos.indices.contains(currentIndex) ? makePage(at: currentIndex) : nil {
            pageController.setViewControllers([first], direction: .forward, animated: false)
        }
    }

    private func setUpChrome() {
        // Translucent dark bars over the photo.
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.tintColor = .white
        topItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        topBar.items = [topItem]
        view.addSubview(topBar)

        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.tintColor = .white
        let showTabs = UIBarButtonItem(image: UIImage(systemName: "square.on.square"), style: .plain, target: self, action: #selector(showTabsTapped))
        showTabs.accessibilityLabel = "Show Tabs"
        bottomBar.items = [.flexibleSpace(), showTabs, .flexibleSpace()]
        view.addSubview(bottomBar)

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

    private func updateTitle() {
        topItem.title = currentPhoto?.fileName
    }

    // MARK: - Save button

    private func updateSaveButton(for status: PhotoSaver.Status) {
        switch status {
        case .saving:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = .white
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

    @objc private func doneTapped() { onClose?() }

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
        updateTitle()
    }
}
