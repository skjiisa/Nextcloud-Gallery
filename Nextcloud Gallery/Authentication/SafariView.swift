//
//  SafariView.swift
//  Nextcloud Gallery
//
//  In-app browser for the Nextcloud web login page.
//

import SwiftUI
import SafariServices

/// Presents the Nextcloud "Grant access" page in an in-app Safari view.
/// The login flow is poll-based, so this view is dismissed programmatically by
/// the login controller once access is granted (no redirect callback needed).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
