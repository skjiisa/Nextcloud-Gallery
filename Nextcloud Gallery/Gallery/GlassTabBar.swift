//
//  GlassTabBar.swift
//  Nextcloud Gallery
//
//  One tab's bottom chrome: a Liquid Glass capsule with new-tab, the tab title +
//  open-count (tap for the switcher), and Settings. Dragging the bar sideways
//  drives the carousel between tabs — so you drag this tab's bar away and the
//  neighbour's slides in behind it.
//
//  The drag is tracked in WINDOW space on purpose: the bar itself rides the
//  carousel's transform, so a local translation would be polluted by the bar's own
//  movement. Absolute window-space location deltas are pure finger movement.
//

import UIKit

final class GlassTabBar: UIView {
    var onNewTab: (() -> Void)?
    var onShowTabs: (() -> Void)?
    var onSettings: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat) -> Void)?

    static let preferredHeight: CGFloat = 56

    private let effectView = UIVisualEffectView(effect: UIGlassEffect())
    private let newTabButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let titleButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let countLabel = PaddedLabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var dragStartX: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildUI()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        addGestureRecognizer(pan)
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

        newTabButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)), for: .normal)
        newTabButton.accessibilityLabel = "New Tab"
        newTabButton.addTarget(self, action: #selector(newTabTapped), for: .touchUpInside)

        settingsButton.setImage(UIImage(systemName: "gearshape", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)), for: .normal)
        settingsButton.accessibilityLabel = "Settings"
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail

        countLabel.font = .systemFont(ofSize: 12, weight: .bold)
        countLabel.textColor = .secondaryLabel
        countLabel.backgroundColor = .tertiarySystemFill
        countLabel.layer.cornerRadius = 6
        countLabel.layer.masksToBounds = true
        countLabel.textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

        let titleStack = UIStackView(arrangedSubviews: [spinner, titleLabel, countLabel])
        titleStack.spacing = 6
        titleStack.alignment = .center
        titleStack.isUserInteractionEnabled = false
        titleButton.addSubview(titleStack)
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleStack.centerXAnchor.constraint(equalTo: titleButton.centerXAnchor),
            titleStack.centerYAnchor.constraint(equalTo: titleButton.centerYAnchor),
            titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: titleButton.leadingAnchor, constant: 8),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: titleButton.trailingAnchor, constant: -8),
        ])
        titleButton.addTarget(self, action: #selector(titleTapped), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [newTabButton, titleButton, settingsButton])
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fill
        titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        newTabButton.setContentHuggingPriority(.required, for: .horizontal)
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        effectView.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -8),
            newTabButton.widthAnchor.constraint(equalToConstant: 44),
            settingsButton.widthAnchor.constraint(equalToConstant: 44),
        ])
    }

    func configure(title: String, count: Int, isWarming: Bool) {
        titleLabel.text = title
        countLabel.text = "\(count)"
        if isWarming { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !isWarming
        titleButton.accessibilityLabel = "Show Tabs, \(count) open"
    }

    // MARK: - Actions

    @objc private func newTabTapped() { onNewTab?() }
    @objc private func titleTapped() { onShowTabs?() }
    @objc private func settingsTapped() { onSettings?() }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let x = recognizer.location(in: window).x
        switch recognizer.state {
        case .began:
            dragStartX = x
        case .changed:
            onDragChanged?(x - dragStartX)
        case .ended, .cancelled, .failed:
            onDragEnded?(x - dragStartX)
        default:
            break
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
