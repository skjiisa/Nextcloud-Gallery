//
//  GlassTabBar.swift
//  Nextcloud Gallery
//
//  One tab's bottom chrome: zoom controls on the left, a tappable title pill in the
//  middle, and Gallery / New-tab / Settings on the right — all in a Liquid Glass
//  capsule. Navigation itself uses the normal navigation stack (the top-bar back
//  button); the bar holds the reach-friendly actions.
//
//  Pill gestures:
//   • tap        → tab switcher
//   • long-press → Safari-style menu (New Tab / Close Tab / Close Other Tabs)
//   • drag       → the bar follows your finger in BOTH axes at once: it slides the
//                  carousel as you move sideways and lifts (with resistance) as you
//                  pull up. Nothing is axis-locked, so a curved or diagonal swipe is
//                  fine — the action is decided on RELEASE by where the swipe was
//                  *heading* (its end position projected forward by its release
//                  velocity, so a quick flick counts): up past the lift threshold
//                  opens the switcher, sideways past the carousel threshold changes
//                  tabs, otherwise everything springs back. A haptic bump fires
//                  whenever you're in switcher-opening territory.
//
//  VoiceOver: the pill activates to the switcher and carries rotor custom actions for
//  new / next / previous / close tab, since none of the above gestures are reachable
//  without sight. Spring animations collapse to short fades under Reduce Motion.
//
//  The drag is tracked in WINDOW space on purpose: the bar rides the carousel's
//  transform, so a local translation would be polluted by the bar's own movement.
//

import UIKit

final class GlassTabBar: UIView {
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onGalleryToggle: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onSettings: (() -> Void)?
    var onShowTabs: (() -> Void)?
    /// Lock / unlock the open photo's zoom (viewer only — the lock button replaces the
    /// gallery button there).
    var onLockToggle: (() -> Void)?
    // Tab management — reached via the pill's long-press menu and VoiceOver actions.
    var onCloseTab: (() -> Void)?
    var onCloseOtherTabs: (() -> Void)?
    var onNextTab: (() -> Void)?
    var onPrevTab: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    /// `(translation, velocity)` of the horizontal drag at release, in window points /
    /// pts-per-sec, so the carousel can flick-switch and continue the momentum.
    var onDragEnded: ((CGFloat, CGFloat) -> Void)?
    /// When a drag resolves to opening the switcher: park the carousel at the active
    /// tab *instantly* so the card snapshot is clean, remembering where the finger
    /// left it. Paired with `onBounceToRest`.
    var onParkForSnapshot: (() -> Void)?
    /// Spring the carousel from where the finger left it back to the active tab, so the
    /// reset reads as a bounce rather than a pop. Runs right after the snapshot.
    var onBounceToRest: (() -> Void)?

    static let preferredHeight: CGFloat = 56

    private let effectView = UIVisualEffectView(effect: UIGlassEffect())
    private let zoomOutButton = GlassTabBar.iconButton("minus.magnifyingglass", accessibility: "Zoom Out")
    private let zoomInButton = GlassTabBar.iconButton("plus.magnifyingglass", accessibility: "Zoom In")
    private let galleryButton = GlassTabBar.iconButton("square.grid.3x3", accessibility: "Gallery")
    // Sits in the gallery button's slot and shows only in the photo viewer (gallery
    // hidden), toggling the open photo's locked zoom.
    private let lockButton = GlassTabBar.iconButton("lock.open", accessibility: "Lock Zoom")
    private let newTabButton = GlassTabBar.iconButton("plus", accessibility: "New Tab")
    private let settingsButton = GlassTabBar.iconButton("gearshape", accessibility: "Settings")

    // Center pill (tap = switcher, long-press = menu, drag = carousel / lift).
    private let pill = PillView()
    private let titleLabel = UILabel()
    private let countLabel = PaddedLabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// Open-tab count, kept from the last `configure` so the long-press menu can hide
    /// "Close Other Tabs" when there's only one.
    private var tabCount = 1

    // Drag state. The pan follows both axes freely; the only latched bit of state is
    // whether the sideways move has grown enough to start driving the carousel (so a
    // near-vertical swipe doesn't needlessly mount neighbour pages).
    private var carouselEngaged = false
    private static let carouselSlop: CGFloat = 10
    private let liftThreshold: CGFloat = 72
    private let maxLift: CGFloat = 92
    private var hapticArmed = false
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildUI()
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(pillTapped))
        pill.addGestureRecognizer(tap)
        pill.addInteraction(UIContextMenuInteraction(delegate: self))
        // VoiceOver can't perform the tap/drag gestures, so route its activation here.
        pill.onActivate = { [weak self] in self?.onShowTabs?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.clipsToBounds = true
        effectView.layer.cornerRadius = GlassTabBar.preferredHeight / 2
        effectView.layer.cornerCurve = .continuous
        addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        zoomOutButton.addTarget(self, action: #selector(zoomOutTapped), for: .touchUpInside)
        zoomInButton.addTarget(self, action: #selector(zoomInTapped), for: .touchUpInside)
        galleryButton.addTarget(self, action: #selector(galleryTapped), for: .touchUpInside)
        lockButton.addTarget(self, action: #selector(lockTapped), for: .touchUpInside)
        lockButton.isHidden = true   // viewer-only; shown via `configure(lockVisible:)`
        newTabButton.addTarget(self, action: #selector(newTabTapped), for: .touchUpInside)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        buildPill()

        let row = UIStackView(arrangedSubviews: [zoomOutButton, zoomInButton, pill, galleryButton, lockButton, newTabButton, settingsButton])
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        pill.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for button in [zoomOutButton, zoomInButton, galleryButton, lockButton, newTabButton, settingsButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        effectView.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: effectView.contentView.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -6),
        ])
    }

    private func buildPill() {
        pill.backgroundColor = .tertiarySystemFill
        pill.layer.cornerRadius = (GlassTabBar.preferredHeight - 16) / 2
        pill.layer.cornerCurve = .continuous
        pill.isAccessibilityElement = true
        pill.accessibilityTraits = .button
        pill.accessibilityHint = "Shows all open tabs"

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countLabel.font = .systemFont(ofSize: 12, weight: .bold)
        countLabel.textColor = .secondaryLabel
        countLabel.backgroundColor = .quaternarySystemFill
        countLabel.layer.cornerRadius = 6
        countLabel.layer.masksToBounds = true
        countLabel.textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Order: count, name, then the warming spinner at the trailing end. The spinner
        // collapses out of the stack when idle (no reserved space), so it pops in/out at
        // the end without disturbing the count or name to its left.
        let stack = UIStackView(arrangedSubviews: [countLabel, titleLabel, spinner])
        stack.spacing = 6
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: pill.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: pill.trailingAnchor, constant: -10),
        ])
    }

    private static func iconButton(_ symbol: String, accessibility: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)), for: .normal)
        button.accessibilityLabel = accessibility
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return button
    }

    func configure(
        title: String,
        count: Int,
        isWarming: Bool,
        galleryEnabled: Bool,
        galleryActive: Bool,
        canZoomIn: Bool,
        canZoomOut: Bool,
        // Viewer-only: when `lockVisible`, the lock button takes the gallery button's
        // place and reflects whether the open photo's zoom is locked.
        lockVisible: Bool = false,
        lockEnabled: Bool = false,
        lockActive: Bool = false
    ) {
        titleLabel.text = title
        countLabel.text = "\(count)"
        // The spinner collapses out when idle (it's last in the pill stack), so it pops
        // in/out at the trailing end without shifting the count or name.
        if isWarming { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !isWarming
        galleryButton.isEnabled = galleryEnabled
        // The Gallery button is a toggle: filled while the flattened gallery is
        // showing (tap to return to folders), hollow while browsing folders.
        let gallerySymbol = galleryActive ? "square.grid.3x3.fill" : "square.grid.3x3"
        galleryButton.setImage(UIImage(systemName: gallerySymbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)), for: .normal)
        galleryButton.accessibilityLabel = galleryActive ? "Exit Gallery" : "Gallery"
        // Gallery and lock share the slot: only one shows at a time.
        galleryButton.isHidden = lockVisible
        lockButton.isHidden = !lockVisible
        if lockVisible {
            let lockSymbol = lockActive ? "lock.fill" : "lock.open"
            lockButton.setImage(UIImage(systemName: lockSymbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)), for: .normal)
            lockButton.isEnabled = lockEnabled
            lockButton.accessibilityLabel = lockActive ? "Unlock Zoom" : "Lock Zoom"
        }
        zoomInButton.isEnabled = canZoomIn
        zoomOutButton.isEnabled = canZoomOut
        tabCount = count
        pill.accessibilityLabel = "\(title), \(count) \(count == 1 ? "tab" : "tabs") open"
        updateAccessibilityActions(count: count)
    }

    /// Exposes the gesture-only tab actions to VoiceOver as rotor custom actions.
    /// Next/Previous appear only when there's somewhere to go.
    private func updateAccessibilityActions(count: Int) {
        var actions = [UIAccessibilityCustomAction(name: "New Tab") { [weak self] _ in
            self?.onNewTab?(); return true
        }]
        if count > 1 {
            actions.append(UIAccessibilityCustomAction(name: "Next Tab") { [weak self] _ in
                self?.onNextTab?(); return true
            })
            actions.append(UIAccessibilityCustomAction(name: "Previous Tab") { [weak self] _ in
                self?.onPrevTab?(); return true
            })
        }
        actions.append(UIAccessibilityCustomAction(name: "Close Tab") { [weak self] _ in
            self?.onCloseTab?(); return true
        })
        pill.accessibilityCustomActions = actions
    }

    // MARK: - Button actions

    @objc private func zoomOutTapped() { onZoomOut?() }
    @objc private func zoomInTapped() { onZoomIn?() }
    @objc private func galleryTapped() { onGalleryToggle?() }
    @objc private func lockTapped() { onLockToggle?() }
    @objc private func newTabTapped() { onNewTab?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func pillTapped() { onShowTabs?() }

    // MARK: - Drag (carousel + lift-to-switcher, unified)

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        // Window space: the bar rides the carousel + its own lift, so only the touch's
        // own translation is a clean read of how far the finger has moved.
        let t = recognizer.translation(in: window)
        let up = max(0, -t.y)       // how far up (the bar only lifts upward)
        let side = t.x              // signed sideways travel

        switch recognizer.state {
        case .began:
            carouselEngaged = false
            hapticArmed = false
            haptic.prepare()

        case .changed:
            // Drive both axes at once so the bar tracks the finger wherever it goes;
            // the carousel only kicks in once there's a real sideways intent.
            if !carouselEngaged, abs(side) > Self.carouselSlop { carouselEngaged = true }
            if carouselEngaged { onDragChanged?(side) }
            applyLift(up)
            updateLiftHaptic(up: up, side: abs(side))

        case .ended:
            commit(up: up, side: side, velocity: recognizer.velocity(in: window))

        case .cancelled, .failed:
            // No commit on a system-cancelled gesture — just settle everything back.
            springBarDown()
            onDragEnded?(0, 0)

        default:
            break
        }
    }

    /// Resolves a finished drag by where it was *heading*, not how it started: the end
    /// position is projected forward by the release velocity (so a quick flick counts
    /// even on little travel), then the dominant projected axis wins if it clears its
    /// threshold.
    private func commit(up: CGFloat, side: CGFloat, velocity: CGPoint) {
        let glide: CGFloat = 0.2   // ~a fifth of a second of coast, matching the carousel
        let projUp = up + max(0, -velocity.y) * glide
        let projSide = side + velocity.x * glide

        if projUp >= abs(projSide) {
            // Up-swipe (or up-flick) wins.
            if projUp >= liftThreshold {
                // Open the switcher. A flick may not have armed the predictive bump, so
                // fire it now.
                if !hapticArmed { haptic.impactOccurred() }
                // Park the bar and carousel at rest just long enough to take a clean
                // card snapshot — this whole block runs in one turn of the run loop, so
                // no in-between frame is ever drawn — then let both BOUNCE home from
                // where the finger left them instead of popping.
                let lifted = transform
                transform = .identity
                onParkForSnapshot?()
                onShowTabs?()           // captures the card, then presents the switcher
                transform = lifted
                springBarDown()
                onBounceToRest?()
            } else {
                springBarDown()
                onDragEnded?(0, 0)   // settle the carousel back on the active tab
            }
        } else {
            // Sideways wins — hand the snap/threshold decision (and the momentum) to
            // the carousel.
            springBarDown()
            onDragEnded?(side, velocity.x)
        }
    }

    /// Lifts the bar with rubber-band resistance: follows the finger at first, then
    /// resists — asymptotic to `maxLift`.
    private func applyLift(_ up: CGFloat) {
        let lift = maxLift * (1 - exp(-up / maxLift))
        transform = CGAffineTransform(translationX: 0, y: -lift)
    }

    /// Fires a single haptic bump exactly while releasing *would* open the switcher —
    /// i.e. the up-swipe is both winning and past the threshold — so the bump always
    /// predicts the outcome, even mid-diagonal.
    private func updateLiftHaptic(up: CGFloat, side: CGFloat) {
        let willOpenSwitcher = up >= liftThreshold && up >= side
        if willOpenSwitcher, !hapticArmed {
            haptic.impactOccurred()
            hapticArmed = true
        } else if !willOpenSwitcher {
            hapticArmed = false
        }
    }

    /// Settles the lifted bar back down — a soft spring, or a brief fade under Reduce
    /// Motion so there's no overshoot.
    private func springBarDown() {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                self.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4, options: [.allowUserInteraction]) {
                self.transform = .identity
            }
        }
    }
}

// MARK: - Long-press tab menu

extension GlassTabBar: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.buildTabMenu()
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        pillPreview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        pillPreview()
    }

    private func buildTabMenu() -> UIMenu {
        var actions = [UIAction(title: "New Tab", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
            self?.onNewTab?()
        }]
        actions.append(UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
            self?.onCloseTab?()
        })
        if tabCount > 1 {
            actions.append(UIAction(title: "Close Other Tabs", image: UIImage(systemName: "xmark.square"), attributes: .destructive) { [weak self] _ in
                self?.onCloseOtherTabs?()
            })
        }
        return UIMenu(children: actions)
    }

    /// Highlights just the rounded pill (not its square bounding box) under the menu.
    private func pillPreview() -> UITargetedPreview {
        let params = UIPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(roundedRect: pill.bounds, cornerRadius: pill.layer.cornerRadius)
        return UITargetedPreview(view: pill, parameters: params)
    }
}

/// The center pill. A plain view for sighted users (its tap/drag live on gesture
/// recognizers), but it routes VoiceOver activation to a closure since those gestures
/// aren't otherwise reachable.
final class PillView: UIView {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}

/// A label with text insets, for the rounded tab-count badge.
final class PaddedLabel: UILabel {
    var textInsets: UIEdgeInsets = .zero { didSet { setNeedsDisplay() } }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + textInsets.left + textInsets.right,
                      height: size.height + textInsets.top + textInsets.bottom)
    }
}
