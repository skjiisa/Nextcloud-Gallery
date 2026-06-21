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

    /// The tab switcher, shown as a child VC (not a modal) so the lift gesture's flying
    /// card can sit *above* the revealed grid and land in its slot. Settings stays modal.
    private var switcherVC: TabSwitcherViewController?
    private var settingsVC: UIViewController?

    // Lift-to-switcher: a full-screen snapshot of the active tab that the finger shifts up
    // off the bar, then drops into its tab-grid slot on release.
    private var flyingCard: UIView?
    /// True during the interactive lift gesture (lift-off → release). Cleared synchronously
    /// on release so a stray re-entrant lift event bails instead of grabbing the card.
    private var liftActive = false
    /// True while the close animation is running, so a repeat close (or a lift that slips
    /// through during it) can't kick off a second teardown.
    private var closingSwitcher = false
    /// Where the finger gripped the card as a fraction of the full-screen card (captured at
    /// lift-off), so the card stays pinned under the finger as it shrinks and floats around.
    private var liftGrip: CGPoint = .zero
    /// How far the lifted tab has shrunk: 0 (full-screen) → 1 (held card). Latched so it
    /// only shrinks — once lifted into a card it stays a card while you float it anywhere.
    private var liftProgress: CGFloat = 0
    /// The active tab's grid-slot frame (root-view space), captured at lift-off — where the
    /// floating card drops on release.
    private var liftTarget: CGRect = .zero
    /// The floating card's scale once fully lifted, and the lift distance to reach it.
    private let heldScale: CGFloat = 0.5

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
        // No carousel sliding while the switcher is present (including its drop/close
        // flights) — a stray touch falling through must not move the pages behind it.
        guard switcherVC == nil else { return }
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
        guard switcherVC == nil, isDragging else { return }
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

    // MARK: - Lift-to-switcher (interactive)

    func switcherLiftBegan(at location: CGPoint) {
        guard switcherVC == nil, !closingSwitcher else { return }
        liftActive = true
        liftProgress = 0
        flyingCard?.removeFromSuperview()   // defensive: never stack two cards
        flyingCard = nil
        let f = view.convert(location, from: nil)
        // Remember where on the (full-screen) page the finger grabbed, so it stays pinned
        // under the finger as the card shrinks. The finger starts low on the bar, so it
        // grips near the card's bottom — the card rides up above it.
        liftGrip = CGPoint(x: f.x / max(1, view.bounds.width), y: f.y / max(1, view.bounds.height))

        // Park the carousel at the active tab and snapshot it for the flying card. Setting
        // the transform and capturing happen in one run-loop turn, so no parked frame is
        // ever drawn — the card starts as an exact copy of what's on screen.
        container.transform = .identity
        tabs.snapshotActiveTab()
        isDragging = false
        rebuildActive()

        // Reveal the switcher grid behind, with the active tab's slot empty (its snapshot
        // is about to drop into it). The pan still owns the touch, so keep the grid inert.
        let switcher = addSwitcherChild()
        switcher.view.isUserInteractionEnabled = false
        switcher.view.layoutIfNeeded()
        switcher.setCardHidden(true, forTab: tabs.activeTabID)

        guard !UIAccessibility.isReduceMotionEnabled else {
            // No flight under Reduce Motion: fade the grid in and let release finalize.
            switcher.setCardHidden(false, forTab: tabs.activeTabID)
            switcher.view.alpha = 0
            UIView.animate(withDuration: 0.2) { switcher.view.alpha = 1 }
            return
        }

        // The lifted tab starts exactly where it already is — full-screen — so nothing
        // pops. From here it floats freely under the finger; release drops it into its slot.
        liftTarget = switcher.cardFrame(forTab: tabs.activeTabID, in: view)
            ?? CGRect(x: view.bounds.midX - 77, y: 120, width: 154, height: 214)
        let card = makeFlyingCard(image: tabs.activeTab.snapshot, frame: view.bounds)
        view.addSubview(card)
        flyingCard = card
    }

    func switcherLiftChanged(at location: CGPoint) {
        // Float the card under the finger: it shrinks as you lift it off the bar (latched,
        // so it only ever shrinks), then follows the finger anywhere you drag it.
        guard let card = flyingCard else { return }
        card.frame = heldFrame(under: view.convert(location, from: nil))
    }

    func switcherLiftEnded(at location: CGPoint, velocity: CGPoint) {
        guard liftActive, let switcher = switcherVC else { return }
        // Claim the gesture synchronously: clear the live state and detach the card *now* so
        // any re-entrant lift/change event bails rather than grabbing the in-flight card.
        liftActive = false
        let card = flyingCard
        flyingCard = nil
        // Reflect the open state immediately (observer re-present is a no-op — child exists).
        tabs.isShowingSwitcher = true

        let reveal = {
            switcher.setCardHidden(false, forTab: self.tabs.activeTabID)
            switcher.view.isUserInteractionEnabled = true
        }
        guard let card else { reveal(); return }   // Reduce Motion (no flying card)
        // Letting go drops it into its slot, carrying the finger's release speed.
        flyCard(card, to: liftTarget, settlingBorderWidth: 3, velocity: velocity) {
            card.removeFromSuperview()
            reveal()
        }
    }

    /// The floating card's frame for a finger at `point` (root-view space): sized by how far
    /// it's been lifted (full-screen → `heldScale`, latched so it only shrinks) and
    /// positioned so the original grip point stays under the finger.
    private func heldFrame(under point: CGPoint) -> CGRect {
        let bounds = view.bounds
        let risen = max(0, liftGrip.y * bounds.height - point.y)
        liftProgress = max(liftProgress, min(risen / (bounds.height * 0.32), 1))
        let scale = 1 - (1 - heldScale) * liftProgress
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let origin = CGPoint(x: point.x - liftGrip.x * size.width, y: point.y - liftGrip.y * size.height)
        return CGRect(origin: origin, size: size)
    }

    /// A snapshot card styled to match a switcher cell's body, so it lands seamlessly.
    /// Built at `frame` up front so its image is correctly sized before any animation —
    /// autoresizing an image view from a zero-size card would fling it into a corner.
    private func makeFlyingCard(image: UIImage?, frame: CGRect) -> UIView {
        let card = UIView(frame: frame)
        card.layer.cornerRadius = TabCardCell.cornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.backgroundColor = .tertiarySystemFill
        card.layer.borderColor = UIColor.tintColor.cgColor
        card.isUserInteractionEnabled = false
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = card.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(imageView)
        return card
    }

    /// Springs the flying card to `target`, fading the active-cell selection ring in as it
    /// lands, then calls `completion`. Carries the release velocity into the spring.
    private func flyCard(_ card: UIView, to target: CGRect, settlingBorderWidth: CGFloat, velocity: CGPoint, completion: @escaping () -> Void) {
        let border = CABasicAnimation(keyPath: "borderWidth")
        border.fromValue = card.layer.borderWidth
        border.toValue = settlingBorderWidth
        border.duration = 0.35
        card.layer.borderWidth = settlingBorderWidth
        card.layer.add(border, forKey: "borderWidth")

        let distance = max(1, hypot(target.midX - card.frame.midX, target.midY - card.frame.midY))
        let initialV = min(hypot(velocity.x, velocity.y) / distance, 6)
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: initialV,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            card.frame = target
        } completion: { _ in completion() }
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

    // MARK: - Switcher (child) & settings (modal) reconciliation

    private func topmostPresenter() -> UIViewController {
        var vc: UIViewController = self
        while let presented = vc.presentedViewController, !presented.isBeingDismissed {
            vc = presented
        }
        return vc
    }

    /// Reconciles the switcher's presence with the model flag. The interactive lift opens
    /// it directly (so `switcherVC` already exists when the flag flips true) — this only
    /// has to handle the non-gesture open (pill tap / VoiceOver) and every close.
    private func syncSwitcher(_ show: Bool) {
        if show {
            guard switcherVC == nil else { return }   // already up (gesture-driven)
            presentSwitcherNonInteractive()
        } else {
            guard switcherVC != nil else { return }
            dismissSwitcher()
        }
    }

    @discardableResult
    private func addSwitcherChild() -> TabSwitcherViewController {
        if let existing = switcherVC { return existing }
        let switcher = TabSwitcherViewController(tabs: tabs)
        switcherVC = switcher
        addChild(switcher)
        switcher.view.frame = view.bounds
        switcher.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // As a child (not a fullScreen modal) the covered carousel + bar would still be in
        // the accessibility tree — mark the switcher modal so VoiceOver ignores them.
        switcher.view.accessibilityViewIsModal = true
        view.addSubview(switcher.view)
        switcher.didMove(toParent: self)
        return switcher
    }

    /// Pill-tap / VoiceOver open: no finger to carry a card, so just reveal the grid with
    /// a gentle scale-and-fade.
    private func presentSwitcherNonInteractive() {
        let switcher = addSwitcherChild()
        switcher.view.layoutIfNeeded()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        switcher.view.alpha = 0
        switcher.view.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.2,
                       options: [.allowUserInteraction]) {
            switcher.view.alpha = 1
            switcher.view.transform = .identity
        }
    }

    /// Close: mirror the open by growing the (now-)active tab's card back to full screen
    /// while the grid fades behind it, then reveal the live tab. The switcher stays attached
    /// until the animation completes (so a lift can't re-open mid-close); `closingSwitcher`
    /// guards against a second close slipping in.
    private func dismissSwitcher() {
        guard let switcher = switcherVC, !closingSwitcher else { return }
        closingSwitcher = true
        liftActive = false
        rebuildActive()   // make sure the live tab is mounted behind before the reveal
        flyingCard?.removeFromSuperview()   // drop any leftover lift card; the close grows its own
        flyingCard = nil

        let tearDown = {
            self.closingSwitcher = false
            self.switcherVC = nil
            switcher.willMove(toParent: nil)
            switcher.view.removeFromSuperview()
            switcher.removeFromParent()
        }

        guard !UIAccessibility.isReduceMotionEnabled, let from = switcher.cardFrame(forTab: tabs.activeTabID, in: view) else {
            UIView.animate(withDuration: 0.2, animations: { switcher.view.alpha = 0 }, completion: { _ in tearDown() })
            return
        }

        let card = makeFlyingCard(image: tabs.activeTab.snapshot, frame: from)
        card.layer.borderWidth = 3
        view.addSubview(card)
        switcher.setCardHidden(true, forTab: tabs.activeTabID)

        let border = CABasicAnimation(keyPath: "borderWidth")
        border.fromValue = 3
        border.toValue = 0
        border.duration = 0.32
        card.layer.borderWidth = 0
        card.layer.add(border, forKey: "borderWidth")

        UIView.animate(withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.2,
                       options: [.allowUserInteraction]) {
            card.frame = self.view.bounds
            switcher.view.alpha = 0
        } completion: { _ in
            card.removeFromSuperview()
            tearDown()
        }
    }

    private func syncSettings(_ show: Bool) {
        if show, settingsVC == nil {
            let settings = UINavigationController(rootViewController: SettingsViewController(environment: environment, tabs: tabs))
            // Observe interactive (swipe-down) dismissal so the flag gets reset — see
            // the delegate below.
            settings.presentationController?.delegate = self
            settingsVC = settings
            topmostPresenter().present(settings, animated: true)
        } else if !show, let settings = settingsVC {
            settingsVC = nil
            settings.dismiss(animated: true)
        }
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

extension RootCarouselViewController: UIAdaptivePresentationControllerDelegate {
    /// The Settings sheet was swiped down to dismiss. Interactive dismissal bypasses our
    /// programmatic teardown, so reset the observed flag and cached controller here —
    /// otherwise `isShowingSettings` stays `true` and the bottom bar's gear (which only
    /// sets it `true`) appears dead for the rest of the launch.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === settingsVC else { return }
        settingsVC = nil
        tabs.isShowingSettings = false
    }
}
