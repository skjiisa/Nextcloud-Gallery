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
    /// How far the finger rises to fully shrink the carousel into held cards — lower = reaches
    /// the smallest size on less travel.
    private var liftFullRise: CGFloat { view.bounds.height * 0.3 }
    /// Where the finger first gripped, as a fraction of the page (captured at touch-down). The
    /// lift keeps the finger at this same fraction down the shrinking card, so the card stays
    /// pinned under the fingertip and can be dragged anywhere on screen.
    private var liftGrip: CGPoint = .zero
    /// True once a fast flick has switched the live transform from 1:1 tracking to springing
    /// toward the finger; stays set for the rest of the gesture so the bounce isn't cut short.
    private var liftSpringing = false
    /// Finger upward speed (pts/sec) above which an up-swipe counts as a fast flick that should
    /// spring to the swipe position rather than track 1:1. Measured from `up` over wall-clock
    /// time, so it's frame-rate independent — a per-frame pixel delta is ~2× larger at 120Hz than
    /// 60Hz, which made the old detector silently not fire on ProMotion devices.
    private let liftFlickVelocity: CGFloat = 1000
    private var lastUp: CGFloat = 0
    private var lastUpTime: CFTimeInterval = 0
    private var upTrackingStarted = false

    // MARK: Manual settle (philosophy B: step the MODEL transform each frame)
    //
    // The release settle steps `container.transform` (the model) toward rest on a
    // CADisplayLink, exactly like the live drag sets it directly each frame. UIView.animate
    // wrote the model to identity-scale synchronously on frame 0, which recomputed the page
    // safe area to full rest in one layout pass — snapping the nav bar + every grid's
    // adjustedContentInset down by the inset delta while only the presentation animated.
    // Stepping the model means the safe area recomputes by a small delta each frame and
    // layout tracks smoothly (the drag is already jump-free for this exact reason).

    /// Drives the settle. One normalized progress spring (0 = release pose, 1 = settled) so
    /// scale / tx / ty all reach rest together on a single rest test in consistent units.
    private var settleLink: CADisplayLink?
    private var settleProgress = SpringScalar()
    /// Frozen at release: the pose to interpolate FROM (the live on-screen transform) and the
    /// resting pose to interpolate TO. We lerp every field by the spring's progress so nothing
    /// can overshoot scale past 1 (which would re-inset the safe area the other way).
    private var settleFromTx: CGFloat = 0
    private var settleFromTy: CGFloat = 0
    private var settleFromScale: CGFloat = 1
    private var settleToTx: CGFloat = 0
    /// Runs once the settle reaches rest (switch tab, rebuild). Cleared on interruption.
    private var settleCompletion: (() -> Void)?
    private var settleLastTime: CFTimeInterval = 0

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
        // Canonical return-to-rest: stop any in-flight settle before we snap to identity, so its
        // link can't keep stepping the transform afterwards (no handoff — we're resetting anyway).
        cancelSettle(handoff: false)
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
        // A finger landed during an in-flight settle. Cancel it (WITHOUT firing its
        // completion, which would switch tabs + rebuild out from under the new gesture) so
        // the settle stepper and this drag don't both write container.transform. isDragging
        // stays true through the whole settle, so this must run before startCarouselIfNeeded's
        // `guard !isDragging` — otherwise it would never get the chance to take over.
        cancelSettle(handoff: true)
        startCarouselIfNeeded(at: location)
        applyDrag(up: up, side: side, at: location)
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
        // Clear the flick state synchronously so a quick re-grab during the snap's settle (which
        // only clears isDragging in its completion) doesn't inherit a stale armed spring.
        liftSpringing = false
        upTrackingStarted = false
    }

    func dragCancelled() {
        snapCarousel(translation: 0, velocity: 0)
        liftSpringing = false
        upTrackingStarted = false
    }

    private func startCarouselIfNeeded(at location: CGPoint) {
        guard !isDragging else { return }
        isDragging = true
        liftSpringing = false
        upTrackingStarted = false
        selectionHaptic.prepare()
        // Where the finger gripped, as a fraction of the page — the lift holds it there as the
        // card shrinks so the card stays under the fingertip.
        let f = view.convert(location, from: nil)
        liftGrip = CGPoint(x: f.x / max(1, view.bounds.width), y: f.y / max(1, view.bounds.height))
        // Snapshot the active tab (content only, no bar) while it's full-screen — ready to fly
        // into the grid if this drag commits to opening the switcher.
        tabs.activeTab.snapshot = controllers[tabs.activeTabID]?.contentSnapshot()
        mountNeighbours()
    }

    /// The one live transform: scrub sideways and shrink upward at the same time, with the card
    /// pinned under the fingertip so it can be dragged anywhere on screen. `up` / `side` are
    /// window-space travel from the touch-down point; `location` is the live finger position.
    private func applyDrag(up: CGFloat, side: CGFloat, at location: CGPoint) {
        // Arm the spring on a fast UPWARD flick (frame-rate-independent speed, lift axis only, so
        // a fast sideways scrub never trips it). Once armed it stays armed for the gesture.
        let now = CACurrentMediaTime()
        if upTrackingStarted, !liftSpringing, !UIAccessibility.isReduceMotionEnabled {
            let dt = now - lastUpTime
            if dt > 0, (up - lastUp) / CGFloat(dt) > liftFlickVelocity, up > liftStartSlop {
                liftSpringing = true
            }
        }
        lastUp = up
        lastUpTime = now
        upTrackingStarted = true

        let progress = liftProgress(forUp: up)
        let scale = 1 - (1 - heldScale) * progress
        // Horizontal: finger-tracking. Rubber-band the over-scroll past the first / last tab
        // while flat — there's no tab to scrub to — but release that resistance as the tab lifts
        // into a card: by then it's being dragged around freely, not scrubbed, so it should track
        // the finger 1:1. Fully free once it's clearly lifted, well before minimum size.
        let active = tabs.activeIndex
        let atStart = active == 0
        let atEnd = active == tabs.tabs.count - 1
        let overscroll = (atStart && side > 0) || (atEnd && side < 0)
        let resistance: CGFloat = overscroll ? min(1, 1.0 / 3.0 + progress) : 1
        let tx = side * resistance
        // Vertical: pin the card under the finger. The bar (what you grabbed) is cropped away as
        // the tab becomes a card, so rather than chase that lost point we hold the finger at the
        // same fraction down the *cropped* card it gripped at — the card sits under the fingertip
        // and keeps following it anywhere, even once fully shrunk. Only while genuinely lifted;
        // dragging back down to/below the start just un-shrinks in place (no downward slide).
        let bounds = view.bounds
        var ty: CGFloat = 0
        if up > 0 {
            let f = view.convert(location, from: nil)
            let pageCardHeight = bounds.height - (bounds.height - bounds.width / TabCardCell.cardAspect) * progress
            ty = (f.y - (liftGrip.y - 0.5) * scale * pageCardHeight) - bounds.height / 2
        }
        setContainerTransform(CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale))
        revealLiftGrid(up: up)
        applyLiftChrome(progress: progress, scale: scale, up: up)
    }

    /// Applies the live drag transform. A steady drag tracks the finger 1:1 (set directly); once a
    /// fast up-flick has armed `liftSpringing` (see `applyDrag`), the transform springs toward the
    /// finger so the tab *bounces* to the swipe position instead of snapping. It stays armed for
    /// the rest of the gesture so a follow-up direct set can't cut the bounce off.
    private func setContainerTransform(_ target: CGAffineTransform) {
        guard liftSpringing, !UIAccessibility.isReduceMotionEnabled else {
            container.transform = target
            return
        }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.container.transform = target
        }
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
        let dur: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.35
        // The crop masks + bar/neighbour fades do NOT drive page layout, so they stay on their
        // own CA / UIView curves over the same duration — they finish together with the settle.
        for id in mountedIDs { controllers[id]?.animateLiftReset(duration: dur) }
        tearDownLiftGrid(animated: true)   // fade the revealed picker away as the carousel grows back
        UIView.animate(withDuration: dur, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            for id in self.mountedIDs {
                self.controllers[id]?.setBarAlpha(1)
                self.controllers[id]?.view.alpha = 1
            }
        }
        // The container itself un-shrinks + slides to centre by STEPPING the model transform
        // each frame (no UIView.animate model snap), so the page safe area — and thus the nav
        // bar + every grid's adjustedContentInset — recomputes smoothly frame-by-frame.
        startSettle(toTx: settled, velocityX: velocity, reduceMotion: UIAccessibility.isReduceMotionEnabled) {
            if target != active {
                self.tabs.activeTabID = self.tabs.tabs[target].id
                self.tabs.save()
            }
            self.isDragging = false
            self.rebuildActive()
        }
    }

    // MARK: Manual settle driver

    /// Starts the manual container settle. Captures the live (presentation) transform as the
    /// "from" pose, the resting pose (identity scale, `toTx` translate, ty 0) as "to", and
    /// steps a single normalized progress spring 0→1 on a CADisplayLink — lerping scale / tx /
    /// ty by that progress so they reach rest together and scale can never overshoot past 1.
    private func startSettle(toTx: CGFloat, velocityX: CGFloat, reduceMotion: Bool, completion: @escaping () -> Void) {
        // Seed from the live presentation transform so a re-grab→release (or a flick spring
        // still in flight) hands off without a jump; pin the model there and stop any CA spring.
        let current = container.layer.presentation()?.affineTransform() ?? container.transform
        container.layer.removeAllAnimations()
        container.transform = current

        settleFromTx = current.tx
        settleFromTy = current.ty
        settleFromScale = current.a            // no rotation in this hierarchy, so a == scaleX
        settleToTx = toTx

        // Convert the release x-velocity (window pts/sec) into progress/sec: progress spans the
        // tx travel, so dp = dx / travel. Capped to keep the spring stable on a hard flick.
        let travel = abs(settleToTx - settleFromTx)
        let progressVelocity: CGFloat = travel > 1 ? min(max(-velocityX / travel, -8), 8) : 0

        // Reduce Motion: critically damped (no overshoot), a hair stiffer so it's brief.
        settleProgress.dampingRatio = reduceMotion ? 1.0 : 0.85
        settleProgress.stiffness = reduceMotion ? (44 * 44) : (36 * 36)
        settleProgress.reset(value: 0, velocity: progressVelocity, target: 1)

        settleCompletion = completion
        settleLastTime = CACurrentMediaTime()
        if settleLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(stepSettle))
            link.add(to: .main, forMode: .common)
            settleLink = link
        }
    }

    @objc private func stepSettle(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(max(0, now - settleLastTime))
        settleLastTime = now
        guard dt > 0 else { return }

        let live = settleProgress.step(dt)
        applySettlePose(progress: settleProgress.value)
        if !live { finishSettle() }
    }

    /// Lerps the container transform between the release pose and the resting pose by `p`.
    private func applySettlePose(progress p: CGFloat) {
        let scale = settleFromScale + (1 - settleFromScale) * p
        let tx = settleFromTx + (settleToTx - settleFromTx) * p
        let ty = settleFromTy + (0 - settleFromTy) * p
        container.transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
    }

    /// Lands exactly on the resting pose (p = 1 ⇒ identity scale, settled tx, ty 0) so there is
    /// no sub-pixel residue to snap, then fires the completion (rebuildActive resets to identity).
    private func finishSettle() {
        settleLink?.invalidate()
        settleLink = nil
        settleProgress.settle()
        applySettlePose(progress: 1)
        let completion = settleCompletion
        settleCompletion = nil
        completion?()
    }

    /// Stops an in-flight settle. `handoff` pins the model to the live presentation so a new
    /// drag continues from where the settle visually was; the completion is dropped either way
    /// (the new gesture, or whatever supersedes it, decides the final state).
    private func cancelSettle(handoff: Bool) {
        guard settleLink != nil else { return }
        settleLink?.invalidate()
        settleLink = nil
        settleCompletion = nil
        if handoff {
            let live = container.layer.presentation()?.affineTransform() ?? container.transform
            container.layer.removeAllAnimations()
            container.transform = live
        }
    }

    // MARK: Commit (release past the up-threshold → open the switcher)

    /// Promotes the picker (already revealed behind the carousel) to the front, swaps the shrunk
    /// live active tab for a snapshot card at its current (already switcher-shaped) frame, and
    /// flies the card into its slot. The live carousel is reset beneath the now-opaque grid.
    private func commitLift(progress: CGFloat, velocity: CGPoint) {
        let activeID = tabs.activeTabID
        // Defensive: a commit normally follows a fresh drag, but if one arrives while a settle
        // is in flight, pin the model to the live position so the snapshot frame below matches.
        cancelSettle(handoff: true)
        // If a fast flick is still springing the carousel, freeze it at its current on-screen
        // position first, so the snapshot card starts exactly where the tab visually is rather
        // than where the spring was heading (otherwise the hand-off jumps).
        if liftSpringing {
            let presented = container.layer.presentation()?.affineTransform() ?? container.transform
            container.layer.removeAllAnimations()
            container.transform = presented
        }
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

// MARK: - Settle spring

/// A damped harmonic oscillator for one scalar, advanced by explicit dt each frame so the
/// settle can be driven off a CADisplayLink (stepping the MODEL container transform, unlike
/// UIView.animate which snaps the model and only animates the presentation). Tuned to feel
/// like the old `usingSpringWithDamping: 0.85` ~0.35s settle. Integrated semi-implicitly
/// (symplectic Euler), stable at 60–120 Hz for the stiffnesses used here.
struct SpringScalar {
    var value: CGFloat = 0
    var velocity: CGFloat = 0
    var target: CGFloat = 0
    /// ω² (ω ≈ 36 rad/s ≈ a 0.35s settle clearly arrived by completion).
    var stiffness: CGFloat = 36 * 36
    /// 1.0 == critically damped (no overshoot); 0.85 == a little liveliness, like the old spring.
    var dampingRatio: CGFloat = 0.85

    private var omega: CGFloat { sqrt(stiffness) }
    private var damping: CGFloat { 2 * dampingRatio * omega }

    mutating func reset(value: CGFloat, velocity: CGFloat, target: CGFloat) {
        self.value = value; self.velocity = velocity; self.target = target
    }

    /// Advances one step of `dt` seconds. Returns false once settled (so the caller can land on
    /// target and stop the link). Sub-steps so a dropped frame can't overshoot the integrator.
    @discardableResult
    mutating func step(_ dt: CGFloat) -> Bool {
        var remaining = min(dt, 1.0 / 30.0)
        let h: CGFloat = 1.0 / 240.0
        while remaining > 0 {
            let s = min(h, remaining)
            let accel = -stiffness * (value - target) - damping * velocity
            velocity += accel * s
            value += velocity * s
            remaining -= s
        }
        return !isAtRest
    }

    /// Rest test in the spring's own (here: normalized progress) units: close in value AND slow.
    var isAtRest: Bool { abs(value - target) < 0.001 && abs(velocity) < 0.01 }

    mutating func settle() { value = target; velocity = 0 }
}
