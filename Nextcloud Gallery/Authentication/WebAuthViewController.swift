//
//  WebAuthViewController.swift
//  Nextcloud Gallery
//
//  WKWebView-based in-app browser for the Nextcloud web login page.
//
//  Used where SFSafariViewController isn't a good fit — notably visionOS, where it
//  punts the page to external Safari. The login flow is poll-based, so this just
//  renders the page and lets the user sign in + grant; the controller dismisses it
//  once polling sees the grant. A "Done" button lets the user back out (polling
//  then continues so an external-Safari finish still completes).
//

import UIKit
import WebKit

final class WebAuthViewController: UIViewController, WKNavigationDelegate {
    private let url: URL
    private let webView = WKWebView()
    private let progress = UIActivityIndicatorView(style: .medium)

    /// Called when the user taps Done (the flow keeps polling regardless).
    var onDone: (() -> Void)?

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: progress)

        webView.load(URLRequest(url: url))
    }

    @objc private func doneTapped() {
        onDone?()
        dismiss(animated: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progress.startAnimating()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.stopAnimating()
        title = webView.title
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progress.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        progress.stopAnimating()
    }
}
