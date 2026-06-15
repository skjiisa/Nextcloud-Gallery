//
//  WebAuthBrowserView.swift
//  Nextcloud Gallery
//
//  WKWebView-based in-app browser for the Nextcloud web login page.
//
//  Used where SFSafariViewController isn't a good fit — notably visionOS, where
//  its delegate/APIs are unavailable and it punts the page to external Safari.
//  The login flow is poll-based, so this just needs to render the page and let
//  the user sign in + grant; the controller dismisses it once polling sees the
//  grant. A "Done" button lets the user back out (polling then continues so an
//  external-Safari finish still completes — see LoginFlowController).
//

import SwiftUI
import WebKit

struct WebAuthBrowserView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var pageTitle = ""
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            LoginWebView(url: url, pageTitle: $pageTitle, isLoading: $isLoading)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(pageTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if isLoading { ProgressView() }
                    }
                }
        }
    }
}

/// Minimal `WKWebView` bridge that reports the page title and load state.
private struct LoginWebView: UIViewRepresentable {
    let url: URL
    @Binding var pageTitle: String
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: LoginWebView

        init(_ parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.pageTitle = webView.title ?? ""
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
