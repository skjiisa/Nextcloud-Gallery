//
//  GlassTabBar.swift
//  Nextcloud Gallery
//
//  One tab's bottom chrome: zoom controls on the left, a tappable title pill in the
//  middle, and Gallery / New-tab / Settings on the right — all in a Liquid Glass
//  capsule. Navigation itself uses the normal navigation stack (the top-bar back
//  button); the bar holds the reach-friendly actions.
//
//  Pill gestures (one pan, axis-locked):
//   • tap            → tab switcher
//   • drag sideways  → slide the carousel between tabs
//   • drag up        → the bar physically lifts with resistance; past a threshold a
//                      haptic bump fires and releasing opens the tab switcher.
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

    // Drag state.
    private var dragStartX: CGFloat = 0
    private var axisLocked = false
    private var draggingHorizontally = false
    private let liftThreshold: CGFloat = 56
    private let maxLift: CGFloat = 92
    private var hapticArmed = false
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildUI()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        addGestureRecognizer(pan)
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
        canZoomIn: Bool,
        canZoomOut: Bool
    ) {
        titleLabel.text = title
        countLabel.text = "\(count)"
        if isWarming { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !isWarming
        galleryButton.isEnabled = galleryEnabled
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

    // MARK: - Drag (carousel + lift-to-switcher)

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: window)
        let translation = recognizer.translation(in: window)
        switch recognizer.state {
        case .began:
            dragStartX = location.x
            axisLocked = false
            draggingHorizontally = false
            hapticArmed = false
            haptic.prepare()
        case .changed:
            if !axisLocked, abs(translation.x) + abs(translation.y) > 8 {
                axisLocked = true
                draggingHorizontally = abs(translation.x) > abs(translation.y)
            }
            guard axisLocked else { return }
            if draggingHorizontally {
                onDragChanged?(location.x - dragStartX)
            } else {
                updateLift(translationY: translation.y)
            }
        case .ended, .cancelled, .failed:
            if draggingHorizontally {
                onDragEnded?(location.x - dragStartX)
            } else if axisLocked {
                let armed = max(0, -translation.y) >= liftThreshold
                springBarDown()
                if armed { onShowTabs?() }
            }
        default:
            break
        }
    }

    /// Lifts the bar with rubber-band resistance and fires a haptic bump once the
    /// open threshold is crossed.
    private func updateLift(translationY: CGFloat) {
        let raw = max(0, -translationY)
        // Follows the finger at first, then resists — asymptotic to `maxLift`.
        let lift = maxLift * (1 - exp(-raw / maxLift))
        transform = CGAffineTransform(translationX: 0, y: -lift)

        let armed = raw >= liftThreshold
        if armed && !hapticArmed {
            haptic.impactOccurred()
            hapticArmed = true
        } else if !armed {
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
