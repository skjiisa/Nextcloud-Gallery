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

    // Lift-to-switcher: on commit, a snapshot of the active tab flies from its (shrunk)
    // position on the carousel into its tab-grid slot. During the drag the live carousel
    // itself shrinks — there's no separate preview overlay to flip on and off.
    private var flyingCard: UIView?
    /// Upward travel (window points) at which a release commits to opening the switcher;
    /// below it the carousel springs back. Matches the bar's own haptic threshold.
    private let liftThreshold: CGFloat = 72
    /// Slop the finger must rise before the carousel starts shrinking, so a level sideways
    /// swipe scrubs tabs at full size without any vertical creep pulling it inward.
    private let liftStartSlop: CGFloat = 8
    /// Window points of upward travel, past ``liftThreshold``, over which the adjacent tabs
    /// fade out — leaving just the lifted card as the drag commits to opening the switcher.
    private let neighbourFadeBand: CGFloat = 50
    /// True while the close animation is running, so a repeat close (or a lift that slips
    /// through during it) can't kick off a second teardown.
    private var closingSwitcher = false
    /// Last switcher visibility the observer acted on. The observer dedupes against this so
    /// an incidental observable read inside present/dismiss (e.g. a tab snapshot refreshed
    /// by the next lift) can't re-fire it and tear the switcher back down spuriously.
    private var lastSwitcherShown = false
    /// The active tab's grid-slot frame (root-view space), captured at commit — where the
    /// flying card drops as the switcher opens.
    private var liftTarget: CGRect = .zero
    /// The shrunk carousel's scale at full lift.
    private let heldScale: CGFloat = 0.5
    /// How far the finger rises to fully shrink the carousel into held cards.
    private var liftFullRise: CGFloat { view.bounds.height * 0.32 }
    /// How far the held card's centre rises at full lift — tuned so the finger keeps holding
    /// the card near its bottom edge (where the bar was). Tweak by feel.
    private var liftCenterRise: CGFloat { view.bounds.height * 0.12 }

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
            // Read (and therefore track) ONLY the flag. Dedupe so a re-fire caused by an
            // incidental observable read inside present/dismiss — e.g. refreshing a tab's
            // snapshot during the next lift — is ignored instead of dismissing the switcher
            // the lift just opened.
            let show = self.tabs.isShowingSwitcher
            guard show != self.lastSwitcherShown else { return }
            self.lastSwitcherShown = show
            self.syncSwitcher(show)
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

    // MARK: - Drag (one continuous gesture: shrink + scrub, committed at release)

    // The bar reports the raw drag every frame; a single progress-driven transform shrinks the
    // whole live carousel as the finger rises and slides it as the finger moves sideways — both
    // at once. There are no separate "carousel" and "lift" modes to flip between: a level swipe
    // scrubs tabs at full size, an upward swipe shrinks the current tab into a card with its
    // neighbours peeking alongside, and any blend in between just works (like a partial swipe-up
    // to the iOS app switcher). Releasing past the up-threshold opens the switcher; otherwise the
    // carousel springs back and snaps to the nearest tab.

    func dragChanged(at location: CGPoint, up: CGFloat, side: CGFloat) {
        // Bail only once the switcher is committed-open.
        guard !tabs.isShowingSwitcher, !closingSwitcher else { return }
        startCarouselIfNeeded(at: location)
        applyDrag(up: up, side: side)
    }

    func dragEnded(at location: CGPoint, up: CGFloat, side: CGFloat, velocity: CGPoint) {
        guard !tabs.isShowingSwitcher, !closingSwitcher else { return }
        // Decide by where the release was *heading* — project travel forward by the flick.
        let projUp = up + max(0, -velocity.y) * 0.2
        let projSide = side + velocity.x * 0.2
        if projUp >= liftThreshold, projUp >= abs(projSide) {
            commitLift(progress: liftProgress(forUp: up), velocity: velocity)   // open the switcher
        } else {
            snapCarousel(translation: side, velocity: velocity.x)              // un-shrink + switch / settle
        }
    }

    func dragCancelled() {
        snapCarousel(translation: 0, velocity: 0)
    }

    private func startCarouselIfNeeded(at location: CGPoint) {
        guard !isDragging else { return }
        isDragging = true
        selectionHaptic.prepare()
        // Snapshot the active tab (content only, no bar) while it's full-screen — ready to fly
        // into the grid if this drag commits to opening the switcher.
        tabs.activeTab.snapshot = controllers[tabs.activeTabID]?.contentSnapshot()
        mountNeighbours()
    }

    /// The one live transform: scrub sideways and shrink upward at the same time. `up` / `side`
    /// are window-space travel from the touch-down point.
    private func applyDrag(up: CGFloat, side: CGFloat) {
        let progress = liftProgress(forUp: up)
        let scale = 1 - (1 - heldScale) * progress
        // Horizontal: finger-tracking, rubber-banded past the first / last tab (nothing there).
        let active = tabs.activeIndex
        let atStart = active == 0
        let atEnd = active == tabs.tabs.count - 1
        let tx = ((atStart && side > 0) || (atEnd && side < 0)) ? side / 3 : side
        // Vertical: lift the shrinking card up toward where the grid sits, keeping the finger
        // near its bottom edge (where the bar was). Scaling around the container's centre means
        // the neighbours, sitting a `slot` away, shrink with it and peek in alongside for free.
        let ty = -progress * liftCenterRise
        container.transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
        revealLiftGrid(up: up)
        applyLiftChrome(progress: progress, scale: scale, up: up)
    }

    /// Brings the switcher grid up *behind* the shrinking carousel and fades it in as the finger
    /// rises — the picker comes into view through the gaps around the cards, then the neighbours
    /// fading out past the threshold (see ``applyLiftChrome``) uncovers it entirely. Created once
    /// per lift and reused; the commit promotes it, a settle tears it down.
    private func revealLiftGrid(up: CGFloat) {
        guard up > liftStartSlop else { return }
        if switcherVC == nil {
            let switcher = addSwitcherChild(behind: true)
            switcher.view.isUserInteractionEnabled = false
            switcher.view.layoutIfNeeded()
            switcher.setCardHidden(true, forTab: tabs.activeTabID)   // active is the floating card
            liftTarget = switcher.cardFrame(forTab: tabs.activeTabID, in: view)
                ?? CGRect(x: view.bounds.midX - 77, y: 120, width: 154, height: 214)
        }
        // Fully in view by the open-threshold, so it's already there as the release commits.
        switcherVC?.view.alpha = min(1, (up - liftStartSlop) / max(1, liftThreshold - liftStartSlop))
    }

    /// Fades out and removes the behind-the-carousel lift grid (used when a lift settles back to
    /// the current tab). A no-op for a plain horizontal snap, where no grid was revealed.
    private func tearDownLiftGrid(animated: Bool) {
        guard let switcher = switcherVC else { return }
        switcherVC = nil
        let remove = {
            switcher.willMove(toParent: nil)
            switcher.view.removeFromSuperview()
            switcher.removeFromParent()
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else { remove(); return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            switcher.view.alpha = 0
        } completion: { _ in remove() }
    }

    /// Maps upward finger travel to lift progress (0 = full-screen tab, 1 = fully shrunk card).
    private func liftProgress(forUp up: CGFloat) -> CGFloat {
        min(max(0, up - liftStartSlop) / liftFullRise, 1)
    }

    /// Gives every mounted page its "card" look as the carousel shrinks — cropping each to the
    /// switcher aspect and fading its bar — and fades the *adjacent* tabs out as the drag pushes
    /// past the open threshold, so the lifted card is left alone at the commit point.
    private func applyLiftChrome(progress: CGFloat, scale: CGFloat, up: CGFloat) {
        let barAlpha = 1 - min(1, max(0, up) / (liftThreshold * 0.8))
        let neighbourAlpha = 1 - min(1, max(0, up - liftThreshold) / neighbourFadeBand)
        let activeID = tabs.activeTabID
        for id in mountedIDs {
            let nav = controllers[id]
            nav?.setLiftProgress(progress, scale: scale, barAlpha: barAlpha)
            nav?.view.alpha = id == activeID ? 1 : neighbourAlpha
        }
    }

    /// Clears the card look from every mounted page at once (no animation), returning them to
    /// plain full-screen tabs — used at commit, where the reset happens behind the opaque grid.
    private func clearLiftChrome() {
        for id in mountedIDs {
            controllers[id]?.setLiftProgress(0, scale: 1, barAlpha: 1)
            controllers[id]?.view.alpha = 1
        }
    }

    private func snapCarousel(translation: CGFloat, velocity: CGFloat) {
        guard isDragging else { return }
        let active = tabs.activeIndex
        let threshold = pageWidth * 0.22
        // Project where a flick would coast to (~a fifth of a second of glide), so a quick
        // flick changes tabs on little travel while a slow drag must clear the distance.
        let projected = translation + velocity * 0.2
        var target = active
        if projected <= -threshold, active < tabs.tabs.count - 1 {
            target = active + 1
        } else if projected >= threshold, active > 0 {
            target = active - 1
        }
        let settled = -CGFloat(target - active) * slot
        if target != active { selectionHaptic.selectionChanged() }
        // Carry the finger's speed into the spring so the snap continues the flick.
        let remaining = max(1, abs(settled - container.transform.tx))
        let initialV = min(abs(velocity) / remaining, 6)
        // Open the crop masks back to full alongside the spring (sublayers a UIView animation
        // block won't touch), then unwind the bar + neighbour fades inside the spring itself.
        let dur: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.35
        for id in mountedIDs { controllers[id]?.animateLiftReset(duration: dur) }
        tearDownLiftGrid(animated: true)   // fade the revealed picker away as the carousel grows back
        animateSnap(initialVelocity: initialV) {
            // A plain translate (scale back to 1, no rise) un-shrinks the carousel and slides
            // the chosen tab to centre in one spring.
            self.container.transform = CGAffineTransform(translationX: settled, y: 0)
            for id in self.mountedIDs {
                self.controllers[id]?.setBarAlpha(1)
                self.controllers[id]?.view.alpha = 1
            }
        } completion: {
            if target != active {
                self.tabs.activeTabID = self.tabs.tabs[target].id
                self.tabs.save()
            }
            self.isDragging = false
            self.rebuildActive()
        }
    }

    // MARK: Commit (release past the up-threshold → open the switcher)

    /// Promotes the picker (already revealed behind the carousel) to the front, swaps the shrunk
    /// live active tab for a snapshot card at its current (already switcher-shaped) frame, and
    /// flies the card into its slot. The live carousel is reset beneath the now-opaque grid.
    private func commitLift(progress: CGFloat, velocity: CGPoint) {
        let activeID = tabs.activeTabID
        // The active page's current on-screen card frame — shrunk, lifted, and cropped to the
        // switcher aspect by the live drag, so the snapshot starts an exact match.
        let startFrame = controllers[activeID]?.liftCardFrame(progress: progress, in: view)
            ?? view.bounds

        // The grid is already revealed (behind the carousel) from the lift; promote it to the
        // opaque, interactive switcher on top — the active slot kept empty for the card to drop
        // into. (A very fast flick from rest can commit before the reveal ran — create it here.)
        let switcher = addSwitcherChild()
        switcher.view.layoutIfNeeded()
        switcher.setCardHidden(true, forTab: activeID)
        liftTarget = switcher.cardFrame(forTab: activeID, in: view)
            ?? CGRect(x: view.bounds.midX - 77, y: 120, width: 154, height: 214)
        view.bringSubviewToFront(switcher.view)
        switcher.view.alpha = 1
        switcher.view.isUserInteractionEnabled = true

        // The snapshot card stands in for the live tab, starting exactly where it sits now: same
        // switcher aspect (so the flight is a pure size/position settle) and bar already faded
        // out, so the swap to the bar-less snapshot is seamless.
        let card = makeFlyingCard(image: tabs.activeTab.snapshot, frame: startFrame)
        view.addSubview(card)
        flyingCard = card

        // Commit the open and tear the live carousel down beneath the (opaque) grid.
        tabs.isShowingSwitcher = true
        isDragging = false
        clearLiftChrome()
        container.transform = .identity
        rebuildActive()

        let reveal = {
            switcher.setCardHidden(false, forTab: activeID)
            switcher.view.isUserInteractionEnabled = true
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            card.removeFromSuperview(); flyingCard = nil; reveal(); return
        }
        // Letting go drops the card into its slot, carrying the finger's release speed.
        flyCard(card, to: liftTarget, settlingBorderWidth: 3, velocity: velocity) {
            card.removeFromSuperview()
            self.flyingCard = nil
            reveal()
        }
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

    /// Adds the switcher grid as a child. `behind` slots it *under* the carousel so the lift's
    /// shrinking cards float above the revealed picker (the live reveal); otherwise it goes on
    /// top (pill-tap / VoiceOver open, and the commit promotion).
    @discardableResult
    private func addSwitcherChild(behind: Bool = false) -> TabSwitcherViewController {
        if let existing = switcherVC { return existing }
        let switcher = TabSwitcherViewController(tabs: tabs)
        switcherVC = switcher
        addChild(switcher)
        switcher.view.frame = view.bounds
        switcher.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // As a child (not a fullScreen modal) the covered carousel + bar would still be in
        // the accessibility tree — mark the switcher modal so VoiceOver ignores them.
        switcher.view.accessibilityViewIsModal = true
        if behind { view.insertSubview(switcher.view, belowSubview: container) }
        else { view.addSubview(switcher.view) }
        switcher.didMove(toParent: self)
        return switcher
    }

    /// Pill-tap / VoiceOver open: no finger to carry a card, so just reveal the grid with
    /// a gentle scale-and-fade.
    private func presentSwitcherNonInteractive() {
        // Refresh the active tab's card (content only) before the grid covers it.
        tabs.activeTab.snapshot = controllers[tabs.activeTabID]?.contentSnapshot()
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

        // Keep the grid opaque behind the growing card: the live tab is already mounted
        // behind it, so fading the grid here would reveal the tab early as a duplicate of
        // the card. It's uncovered only at the end, when the card is full-screen and both
        // the card and the grid are removed together.
        UIView.animate(withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.2,
                       options: [.allowUserInteraction]) {
            card.frame = self.view.bounds
        } completion: { _ in
            card.removeFromSuperview()
            tearDown()
            // The bar isn't in the snapshot, so the revealed tab has none yet — fade the live
            // bar in (at rest) so it appears smoothly rather than popping in.
            self.controllers[self.tabs.activeTabID]?.fadeBarIn()
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
