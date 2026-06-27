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
//   • drag       → the bar reports both axes raw every frame and the coordinator drives a
//                  single continuous transform on the carousel (see
//                  ``RootCarouselViewController``): moving sideways scrubs between tabs,
//                  pulling up shrinks the current tab into a card with its neighbours peeking
//                  in alongside — both at once, like a partial swipe-up to the iOS app
//                  switcher. Nothing is axis-locked or mode-switched; a curved or diagonal
//                  swipe just blends the two. A haptic bumps once the drag is far enough up
//                  that releasing would open the switcher. The action is decided on RELEASE by
//                  where the drag was *heading* (end position projected forward by release
//                  velocity, so a quick flick counts): a projected up-flick past the threshold
//                  opens the switcher (the shrunk card flies into its grid slot), sideways past
//                  the carousel threshold changes tabs, otherwise everything springs back.
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
    /// The drag moved. `(location, up, side)` in window space: the finger's point, how far
    /// above the start it is, and its signed sideways travel. The bar itself never decides
    /// between carousel and lift — it just reports the raw drag every frame and lets the
    /// coordinator drive both, so the user can change their mind freely until release.
    var onDrag: ((CGPoint, CGFloat, CGFloat) -> Void)?
    /// The finger let go: `(location, up, side, velocity)` in window space / points / pts-per-
    /// sec, so the coordinator commits whichever action the release crossed (or settles).
    var onDragRelease: ((CGPoint, CGFloat, CGFloat, CGPoint) -> Void)?
    /// The gesture was cancelled by the system — settle everything back, commit nothing.
    var onDragCancel: (() -> Void)?

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

    // The pan reports both axes raw every frame; the coordinator decides between carousel and
    // lift and can switch between them mid-drag, so nothing is latched here. `hapticArmed`
    // fires one bump when the drag first looks like it'll open the switcher on release.
    private var hapticArmed = false
    /// Upward travel at which releasing would open the switcher — used only to arm the haptic.
    private let liftThreshold: CGFloat = 72
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

    // MARK: - Drag (carousel + lift-to-switcher, decided by the coordinator at release)

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        // Window space: the bar rides the carousel + its own lift, so only the touch's
        // own translation is a clean read of how far the finger has moved.
        let t = recognizer.translation(in: window)
        let loc = recognizer.location(in: window)
        let up = max(0, -t.y)       // how far up
        let side = t.x              // signed sideways travel

        switch recognizer.state {
        case .began:
            hapticArmed = false
            haptic.prepare()

        case .changed:
            // Report the raw drag — the coordinator drives carousel vs. lift and can swap
            // between them as the finger changes direction; nothing is committed yet.
            updateLiftHaptic(up: up, side: abs(side))
            onDrag?(loc, up, side)

        case .ended:
            onDragRelease?(loc, up, side, recognizer.velocity(in: window))

        case .cancelled, .failed:
            onDragCancel?()

        default:
            break
        }
    }

    /// Bumps once when the drag first looks like a release would open the switcher (clearly
    /// upward, past the threshold), re-arming if it stops looking that way so a wavering drag
    /// can announce it again.
    private func updateLiftHaptic(up: CGFloat, side: CGFloat) {
        let willLift = up >= liftThreshold && up >= side
        if willLift, !hapticArmed {
            haptic.impactOccurred()
            hapticArmed = true
        } else if !willLift {
            hapticArmed = false
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
