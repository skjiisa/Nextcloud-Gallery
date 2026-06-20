//
//  GlassTabBar.swift
//  Nextcloud Gallery
//
//  One tab's bottom chrome: zoom controls on the left, a tappable title pill in the
//  middle, and Gallery / New-tab / Settings on the right — all in a Liquid Glass
//  capsule. Navigation itself uses the normal navigation stack (the top-bar back
//  button); the bar holds the reach-friendly actions.
//
//  Pill gestures (one free-direction pan):
//   • tap   → tab switcher
//   • drag  → the bar follows your finger in BOTH axes at once: it slides the
//             carousel as you move sideways and lifts (with resistance) as you pull
//             up. Nothing is axis-locked, so a curved or diagonal swipe is fine — the
//             action is decided on RELEASE by whichever direction you ended up going:
//             up past the lift threshold opens the switcher, sideways past the
//             carousel threshold changes tabs, otherwise everything springs back. A
//             haptic bump fires whenever you're in switcher-opening territory, so the
//             bump always predicts what releasing will do.
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
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat) -> Void)?
    /// Reset the carousel to the active tab *immediately* (no snap animation). Used
    /// when a drag resolves to opening the switcher: the live screen must be back at
    /// rest before its card snapshot is taken.
    var onDragCancelled: (() -> Void)?

    static let preferredHeight: CGFloat = 56

    private let effectView = UIVisualEffectView(effect: UIGlassEffect())
    private let zoomOutButton = GlassTabBar.iconButton("minus.magnifyingglass", accessibility: "Zoom Out")
    private let zoomInButton = GlassTabBar.iconButton("plus.magnifyingglass", accessibility: "Zoom In")
    private let galleryButton = GlassTabBar.iconButton("square.grid.3x3", accessibility: "Gallery")
    private let newTabButton = GlassTabBar.iconButton("plus", accessibility: "New Tab")
    private let settingsButton = GlassTabBar.iconButton("gearshape", accessibility: "Settings")

    // Center pill (tap = switcher, drag = carousel / lift).
    private let pill = UIView()
    private let titleLabel = UILabel()
    private let countLabel = PaddedLabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    // Drag state. The pan follows both axes freely; the only latched bit of state is
    // whether the sideways move has grown enough to start driving the carousel (so a
    // near-vertical swipe doesn't needlessly mount neighbour pages).
    private var carouselEngaged = false
    private static let carouselSlop: CGFloat = 10
    private let liftThreshold: CGFloat = 56
    private let maxLift: CGFloat = 92
    private var hapticArmed = false
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildUI()
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(pillTapped))
        pill.addGestureRecognizer(tap)
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
        newTabButton.addTarget(self, action: #selector(newTabTapped), for: .touchUpInside)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        buildPill()

        let row = UIStackView(arrangedSubviews: [zoomOutButton, zoomInButton, pill, galleryButton, newTabButton, settingsButton])
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        pill.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for button in [zoomOutButton, zoomInButton, galleryButton, newTabButton, settingsButton] {
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

        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, countLabel])
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
        canZoomOut: Bool
    ) {
        titleLabel.text = title
        countLabel.text = "\(count)"
        if isWarming { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !isWarming
        galleryButton.isEnabled = galleryEnabled
        // The Gallery button is a toggle: filled while the flattened gallery is
        // showing (tap to return to folders), hollow while browsing folders.
        let gallerySymbol = galleryActive ? "square.grid.3x3.fill" : "square.grid.3x3"
        galleryButton.setImage(UIImage(systemName: gallerySymbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)), for: .normal)
        galleryButton.accessibilityLabel = galleryActive ? "Exit Gallery" : "Gallery"
        zoomInButton.isEnabled = canZoomIn
        zoomOutButton.isEnabled = canZoomOut
        pill.accessibilityLabel = "\(title), \(count) tabs open. Show switcher."
    }

    // MARK: - Button actions

    @objc private func zoomOutTapped() { onZoomOut?() }
    @objc private func zoomInTapped() { onZoomIn?() }
    @objc private func galleryTapped() { onGalleryToggle?() }
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
            commit(up: up, side: side)

        case .cancelled, .failed:
            // No commit on a system-cancelled gesture — just settle everything back.
            springBarDown()
            onDragEnded?(0)

        default:
            break
        }
    }

    /// Resolves a finished drag by its *final* direction rather than how it started:
    /// the dominant axis (up vs. sideways) wins, and only if it cleared its threshold.
    private func commit(up: CGFloat, side: CGFloat) {
        if up >= abs(side) {
            // Up-swipe wins.
            if up >= liftThreshold {
                // Open the switcher. Snap the live surfaces back to rest *first* so the
                // tab's card snapshot (taken in `onShowTabs`) isn't caught mid-drag.
                onDragCancelled?()
                transform = .identity
                onShowTabs?()
            } else {
                springBarDown()
                onDragEnded?(0)   // settle the carousel back on the active tab
            }
        } else {
            // Sideways wins — hand the snap/threshold decision to the carousel.
            springBarDown()
            onDragEnded?(side)
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

    private func springBarDown() {
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4, options: [.allowUserInteraction]) {
            self.transform = .identity
        }
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
