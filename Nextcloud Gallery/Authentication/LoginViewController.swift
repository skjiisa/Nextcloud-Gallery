//
//  LoginViewController.swift
//  Nextcloud Gallery
//
//  Sign-in screen: enter a server address and authenticate via the web flow
//  (Login Flow v2). Drives the reusable ``LoginFlowController`` and presents an
//  in-app browser for the grant step.
//

import UIKit
import SafariServices

final class LoginViewController: UIViewController, SFSafariViewControllerDelegate {
    private let environment: AppEnvironment
    private let controller = LoginFlowController()
    private var observation: ObservationToken?

    /// The URL currently shown in a presented browser, so we present/dismiss only
    /// on actual changes (and don't re-present the same page each render).
    private var presentedBrowserURL: URL?

    // UI
    private let heroImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let serverField = UITextField()
    private let signInButton = UIButton(configuration: .filled())
    private let errorLabel = UILabel()
    private lazy var signInStack = UIStackView(arrangedSubviews: [serverField, signInButton])

    // "Finishing in external Safari" affordance.
    private let waitingLabel = UILabel()
    private let reopenButton = UIButton(configuration: .bordered())
    private let cancelButton = UIButton(configuration: .plain())
    private lazy var waitingStack: UIStackView = {
        let spinnerRow = UIStackView(arrangedSubviews: [makeSpinner(), waitingLabel])
        spinnerRow.spacing = 8
        spinnerRow.alignment = .center
        return UIStackView(arrangedSubviews: [spinnerRow, reopenButton, cancelButton])
    }()

    private let contentStack = UIStackView()
    private var contentWidthConstraint: NSLayoutConstraint?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()

        controller.onComplete = { [weak self] credentials in
            self?.environment.completeLogin(credentials)
        }

        // Re-render the whole screen whenever the flow's observable state changes.
        observation = observeChanges { [weak self] in self?.render() }
    }

    // MARK: - UI construction

    private func buildUI() {
        let metrics = LayoutMetrics(traits: traitCollection)

        heroImageView.image = UIImage(systemName: "photo.stack")
        heroImageView.preferredSymbolConfiguration = .init(pointSize: metrics.largeIconSize)
        heroImageView.tintColor = view.tintColor
        heroImageView.contentMode = .scaleAspectFit

        titleLabel.text = "Nextcloud Gallery"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle).bold()
        titleLabel.textAlignment = .center

        subtitleLabel.text = "Sign in to browse your photos."
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center

        serverField.placeholder = "cloud.example.com"
        serverField.borderStyle = .roundedRect
        serverField.textContentType = .URL
        serverField.keyboardType = .URL
        serverField.autocapitalizationType = .none
        serverField.autocorrectionType = .no
        serverField.returnKeyType = .go
        serverField.delegate = self
        serverField.addTarget(self, action: #selector(serverTextChanged), for: .editingChanged)

        var signInConfig = signInButton.configuration ?? .filled()
        signInConfig.title = "Sign In"
        signInConfig.buttonSize = .large
        signInButton.configuration = signInConfig
        signInButton.addTarget(self, action: #selector(signInTapped), for: .touchUpInside)

        let headlineStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        headlineStack.axis = .vertical
        headlineStack.spacing = metrics.controlSpacing / 2

        signInStack.axis = .vertical
        signInStack.spacing = metrics.controlSpacing

        waitingLabel.text = "Waiting for you to finish signing in…"
        waitingLabel.font = .preferredFont(forTextStyle: .subheadline)
        waitingLabel.textColor = .secondaryLabel
        waitingLabel.numberOfLines = 0
        reopenButton.configuration?.title = "Reopen Sign-In Page"
        reopenButton.addTarget(self, action: #selector(reopenTapped), for: .touchUpInside)
        cancelButton.configuration?.title = "Cancel"
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        waitingStack.axis = .vertical
        waitingStack.spacing = metrics.controlSpacing
        waitingStack.alignment = .center

        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = metrics.majorSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        [heroImageView, headlineStack, signInStack, waitingStack, errorLabel]
            .forEach { contentStack.addArrangedSubview($0) }
        view.addSubview(contentStack)

        let width = contentStack.widthAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.widthAnchor)
        let preferredWidth: NSLayoutConstraint
        if let maxWidth = metrics.maxReadableWidth {
            preferredWidth = contentStack.widthAnchor.constraint(equalToConstant: maxWidth)
        } else {
            preferredWidth = contentStack.widthAnchor.constraint(equalTo: view.layoutMarginsGuide.widthAnchor)
        }
        preferredWidth.priority = .defaultHigh
        contentWidthConstraint = preferredWidth

        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            width, preferredWidth,
        ])
    }

    private func makeSpinner() -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return spinner
    }

    // MARK: - Render from state

    private func render() {
        let phase = controller.phase
        let awaiting = controller.isAwaitingInBackground

        signInStack.isHidden = awaiting
        waitingStack.isHidden = !awaiting

        // Sign-in button: spinner while busy, disabled with no server entered.
        signInButton.configuration?.showsActivityIndicator = controller.isBusy && !awaiting
        signInButton.configuration?.title = (controller.isBusy && !awaiting) ? nil : "Sign In"
        signInButton.isEnabled = !controller.serverURLString.isEmpty && !controller.isBusy
        serverField.isEnabled = !controller.isBusy

        if case let .failed(message) = phase {
            errorLabel.text = message
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }

        syncBrowser(controller.browserURL?.url)
    }

    /// Presents or dismisses the in-app browser to match the flow's `browserURL`.
    private func syncBrowser(_ url: URL?) {
        if let url, presentedBrowserURL != url {
            presentedBrowserURL = url
            presentBrowser(for: url)
        } else if url == nil, presentedBrowserURL != nil {
            presentedBrowserURL = nil
            presentedViewController?.dismiss(animated: true)
        }
    }

    private func presentBrowser(for url: URL) {
        // SFSafariViewController is the best native experience on iOS; visionOS
        // doesn't fully support it, so use an in-app WKWebView there.
        #if os(visionOS)
        let web = WebAuthViewController(url: url)
        web.onDone = { [weak self] in self?.browserClosedByUser() }
        let nav = UINavigationController(rootViewController: web)
        present(nav, animated: true)
        #else
        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        present(safari, animated: true)
        #endif
    }

    private func browserClosedByUser() {
        presentedBrowserURL = nil
        controller.browserDismissed()
    }

    // MARK: - Actions

    @objc private func serverTextChanged() {
        controller.serverURLString = serverField.text ?? ""
    }

    @objc private func signInTapped() {
        view.endEditing(true)
        Task { await controller.start() }
    }

    @objc private func reopenTapped() { controller.reopenBrowser() }
    @objc private func cancelTapped() { controller.cancel() }

    // MARK: - SFSafariViewControllerDelegate

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        browserClosedByUser()
    }
}

// MARK: - UITextFieldDelegate

extension LoginViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        Task { await controller.start() }
        return true
    }
}

// MARK: - Font helper

extension UIFont {
    /// A bold version of this font, preserving its size/metrics.
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
