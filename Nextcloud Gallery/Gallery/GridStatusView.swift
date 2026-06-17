//
//  GridStatusView.swift
//  Nextcloud Gallery
//
//  The centered loading / empty / error overlay shown over a grid when it has no
//  content — the UIKit stand-in for SwiftUI's `ProgressView` and
//  `ContentUnavailableView`.
//

import UIKit

final class GridStatusView: UIView {
    private let spinner = UIActivityIndicatorView(style: .large)
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(configuration: .bordered())
    private let stack = UIStackView()

    /// Invoked when the user taps Retry in the error state.
    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = .secondaryLabel
        glyph.preferredSymbolConfiguration = .init(pointSize: 40)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        retryButton.configuration?.title = "Retry"
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        [spinner, glyph, titleLabel, messageLabel, retryButton].forEach(stack.addArrangedSubview)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
        hide()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showLoading() {
        isHidden = false
        spinner.startAnimating()
        spinner.isHidden = false
        [glyph, titleLabel, messageLabel, retryButton].forEach { $0.isHidden = true }
    }

    func showEmpty(symbol: String, title: String, message: String) {
        configureMessage(symbol: symbol, title: title, message: message, showRetry: false)
    }

    func showError(symbol: String, title: String, message: String) {
        configureMessage(symbol: symbol, title: title, message: message, showRetry: true)
    }

    func hide() {
        isHidden = true
        spinner.stopAnimating()
    }

    private func configureMessage(symbol: String, title: String, message: String, showRetry: Bool) {
        isHidden = false
        spinner.stopAnimating()
        spinner.isHidden = true
        glyph.image = UIImage(systemName: symbol)
        glyph.isHidden = false
        titleLabel.text = title
        titleLabel.isHidden = false
        messageLabel.text = message
        messageLabel.isHidden = false
        retryButton.isHidden = !showRetry
    }

    @objc private func retryTapped() { onRetry?() }
}
