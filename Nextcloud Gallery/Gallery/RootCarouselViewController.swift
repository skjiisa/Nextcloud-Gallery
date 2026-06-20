//
//  RootCarouselViewController.swift
//  Nextcloud Gallery
//
//  Lays the open tabs out as a horizontal carousel. Only the active tab is mounted
//  at rest; dragging a tab's bottom bar mounts its neighbours, slides the pages
//  (each its own navigation stack + bar), and snaps to the nearest tab on release.
//
//  The live drag is a single transform on the page container — pages sit at fixed
//  slots, so the heavy navigation stacks aren't relaid out every frame; only the
//  cheap container transform follows the finger (mirrors the old SwiftUI carousel).
//

import UIKit

final class RootCarouselViewController: UIViewController, CarouselDragHandling {
    private let environment: AppEnvironment
    private let tabs: TabsModel
    private let client: NextcloudClient

    private let container = UIView()

    /// All created tab pages, cached by tab id so switching back preserves a tab's
    /// navigation + scroll state. Only the mounted ones (active, plus neighbours
    /// mid-drag) have their views attached.
    private var controllers: [UUID: BrowseNavController] = [:]
    private var mountedIDs: Set<UUID> = []

    private var isDragging = false
    private let peekGap: CGFloat = 16
    private var pageWidth: CGFloat { view.bounds.width }
    private var slot: CGFloat { pageWidth + peekGap }

    /// A soft tick when the carousel lands on a different tab — mirrors the viewer's
    /// page-change feedback so tab and photo paging feel the same.
    private let selectionHaptic = UISelectionFeedbackGenerator()

    // Presented modals (driven by the tabs model).
    private var switcherVC: TabSwitcherViewController?
    private var settingsVC: UIViewController?

    private var structureObservation: ObservationToken?
    private var switcherObservation: ObservationToken?
    private var settingsObservation: ObservationToken?

    init(environment: AppEnvironment, tabs: TabsModel, client: NextcloudClient) {
        self.environment = environment
        self.tabs = tabs
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        container.frame = view.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.clipsToBounds = false
        view.addSubview(container)

        rebuildActive()
        observeModel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !isDragging { positionPages() }
    }

    // MARK: - Observation

    private func observeModel() {
        structureObservation = observeChanges { [weak self] in
            guard let self else { return }
            // Touch the structural state so changes re-fire.
            _ = self.tabs.tabs.map(\.id)
            _ = self.tabs.activeTabID
            if !self.isDragging { self.rebuildActive() }
        }
        switcherObservation = observeChanges { [weak self] in
            guard let self else { return }
            self.syncSwitcher(self.tabs.isShowingSwitcher)
        }
        settingsObservation = observeChanges { [weak self] in
            guard let self else { return }
            self.syncSettings(self.tabs.isShowingSettings)
        }
    }

    // MARK: - Page mounting

    private func controller(for tab: BrowseTab) -> BrowseNavController {
        if let existing = controllers[tab.id] { return existing }
        let nav = BrowseNavController(tab: tab, environment: environment, client: client, tabsModel: tabs, dragHandler: self)
        controllers[tab.id] = nav
        return nav
    }

    private func mount(_ tab: BrowseTab) {
        guard !mountedIDs.contains(tab.id) else { return }
        let nav = controller(for: tab)
        addChild(nav)
        container.addSubview(nav.view)
        nav.didMove(toParent: self)
        mountedIDs.insert(tab.id)
    }

    private func unmount(_ id: UUID) {
        guard mountedIDs.contains(id), let nav = controllers[id] else { return }
        nav.willMove(toParent: nil)
        nav.view.removeFromSuperview()
        nav.removeFromParent()
        mountedIDs.remove(id)
    }

    /// Drops cached pages for tabs that have been closed.
    private func pruneClosedTabs() {
        let live = Set(tabs.tabs.map(\.id))
        for id in controllers.keys where !live.contains(id) {
            unmount(id)
            controllers[id] = nil
        }
    }

    /// Mounts only the active tab (the at-rest state) and positions it centered.
    private func rebuildActive() {
        pruneClosedTabs()
        let active = tabs.activeTab
        for id in mountedIDs where id != active.id { unmount(id) }
        mount(active)
        container.transform = .identity
        positionPages()
    }

    private func mountNeighbours() {
        let active = tabs.activeIndex
        for i in [active - 1, active, active + 1] where tabs.tabs.indices.contains(i) {
            mount(tabs.tabs[i])
        }
        positionPages()
    }

    private func positionPages() {
        let active = tabs.activeIndex
        for id in mountedIDs {
            guard let index = tabs.tabs.firstIndex(where: { $0.id == id }),
                  let nav = controllers[id] else { continue }
            nav.view.frame = CGRect(x: CGFloat(index - active) * slot, y: 0, width: pageWidth, height: view.bounds.height)
        }
    }

    // MARK: - CarouselDragHandling

    func carouselDragChanged(translation: CGFloat) {
        if !isDragging {
            isDragging = true
            selectionHaptic.prepare()
            // Snapshot the active tab while it's still full-screen, for its card.
            tabs.snapshotActiveTab()
            mountNeighbours()
        }
        let active = tabs.activeIndex
        let atStart = active == 0
        let atEnd = active == tabs.tabs.count - 1
        // Rubber-band past the first/last tab — there's nothing there.
        let offset = ((atStart && translation > 0) || (atEnd && translation < 0)) ? translation / 3 : translation
        container.transform = CGAffineTransform(translationX: offset, y: 0)
    }

    func carouselDragEnded(translation: CGFloat, velocity: CGFloat) {
        guard isDragging else { return }
        let active = tabs.activeIndex
        let threshold = pageWidth * 0.22
        // Project where a flick would coast to (~a fifth of a second of glide), so a
        // quick flick changes tabs on little travel — like a paged scroll view — while
        // a slow drag still needs to clear the distance threshold.
        let projected = translation + velocity * 0.2
        var target = active
        if projected <= -threshold, active < tabs.tabs.count - 1 {
            target = active + 1
        } else if projected >= threshold, active > 0 {
            target = active - 1
        }

        let settled = -CGFloat(target - active) * slot
        if target != active { selectionHaptic.selectionChanged() }
        // Carry the finger's speed into the spring so the snap continues the flick
        // rather than restarting from a standstill.
        let remaining = max(1, abs(settled - container.transform.tx))
        let initialV = min(abs(velocity) / remaining, 6)
        animateSnap(initialVelocity: initialV) {
            self.container.transform = CGAffineTransform(translationX: settled, y: 0)
        } completion: {
            if target != active {
                self.tabs.activeTabID = self.tabs.tabs[target].id
                self.tabs.save()
            }
            self.isDragging = false
            self.rebuildActive()
        }
    }

    func carouselDragCancelled() {
        guard isDragging else { return }
        // Snap straight back to the active tab — no animation — so the screen is at
        // rest the instant the caller snapshots it for the switcher.
        isDragging = false
        rebuildActive()
    }

    /// Runs the carousel's snap-into-place animation, honouring Reduce Motion (a short
    /// linear settle instead of a spring with overshoot).
    private func animateSnap(initialVelocity: CGFloat, _ animations: @escaping () -> Void, completion: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                animations()
            } completion: { _ in completion() }
        } else {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: initialVelocity, options: [.curveEaseOut, .allowUserInteraction]) {
                animations()
            } completion: { _ in completion() }
        }
    }

    // MARK: - Modal reconciliation

    private func topmostPresenter() -> UIViewController {
        var vc: UIViewController = self
        while let presented = vc.presentedViewController, !presented.isBeingDismissed {
            vc = presented
        }
        return vc
    }

    private func syncSwitcher(_ show: Bool) {
        if show, switcherVC == nil {
            let switcher = TabSwitcherViewController(tabs: tabs)
            switcher.modalPresentationStyle = .fullScreen
            switcherVC = switcher
            topmostPresenter().present(switcher, animated: true)
        } else if !show, let switcher = switcherVC {
            switcherVC = nil
            switcher.dismiss(animated: true)
        }
    }

    private func syncSettings(_ show: Bool) {
        if show, settingsVC == nil {
            let settings = UINavigationController(rootViewController: SettingsViewController(environment: environment, tabs: tabs))
            settingsVC = settings
            topmostPresenter().present(settings, animated: true)
        } else if !show, let settings = settingsVC {
            settingsVC = nil
            settings.dismiss(animated: true)
        }
    }
}
