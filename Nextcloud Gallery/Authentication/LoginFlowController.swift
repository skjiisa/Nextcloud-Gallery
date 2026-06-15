//
//  LoginFlowController.swift
//  Nextcloud Gallery
//
//  Drives the Nextcloud Login Flow v2 (web auth + polling).
//

import Foundation
import Observation

/// Runs the web login flow: requests a login URL, presents it (the view shows a
/// browser bound to ``browserURL``), polls until the user grants access, then
/// resolves the session and reports back via ``onComplete``.
@Observable
@MainActor
final class LoginFlowController {
    enum Phase: Equatable {
        case idle
        case starting
        case awaitingGrant
        case finishing
        case failed(String)
    }

    /// Server address typed by the user.
    var serverURLString = ""
    /// Current state of the flow, drives the UI.
    private(set) var phase: Phase = .idle
    /// When non-nil, the view presents an in-app browser for this URL.
    var browserURL: IdentifiableURL?

    /// Called with the resolved credentials once login completes.
    var onComplete: ((AccountCredentials) -> Void)?

    private var pollTask: Task<Void, Never>?
    /// The web login URL for the in-flight flow, kept so the browser can be
    /// reopened if the user (or the system, on visionOS) closes the in-app view.
    private var loginURL: URL?

    /// How long to keep polling for a grant before giving up. Comfortably within
    /// the server's login-flow token lifetime, but bounded so we don't poll forever.
    private let pollDeadline: Duration = .seconds(15 * 60)

    var isBusy: Bool {
        switch phase {
        case .starting, .awaitingGrant, .finishing: true
        case .idle, .failed: false
        }
    }

    /// True while we're polling but the in-app browser is closed — e.g. the login
    /// moved to external Safari, or the user dismissed the in-app view. The view
    /// shows a "waiting / reopen / cancel" affordance in this state.
    var isAwaitingInBackground: Bool {
        if case .awaitingGrant = phase { return browserURL == nil }
        return false
    }

    /// Begins the login flow for the entered server address.
    func start() async {
        guard !isBusy else { return }
        guard let serverURL = Self.normalizedServerURL(from: serverURLString) else {
            phase = .failed(GalleryError.invalidServerURL.userMessage)
            return
        }

        phase = .starting
        let begin: (login: URL, endpoint: String, token: String)
        do {
            begin = try await NextcloudClient.beginLogin(serverURL: serverURL)
        } catch {
            phase = .failed(GalleryError.loginFailed.userMessage)
            return
        }

        loginURL = begin.login
        browserURL = IdentifiableURL(url: begin.login)
        phase = .awaitingGrant
        startPolling(token: begin.token, endpoint: begin.endpoint)
    }

    /// The in-app browser sheet was dismissed. We deliberately keep polling: the
    /// user may be finishing in external Safari (the case on visionOS, where the
    /// system can punt the page out of the in-app view), or they closed it by
    /// accident and can reopen. Explicit ``cancel()`` is the only thing that stops
    /// the flow.
    func browserDismissed() {
        browserURL = nil
    }

    /// Re-presents the in-app browser for the in-flight flow (e.g. after the user
    /// dismissed it but still wants to sign in here rather than in Safari).
    func reopenBrowser() {
        guard case .awaitingGrant = phase, let loginURL else { return }
        browserURL = IdentifiableURL(url: loginURL)
    }

    /// Cancels an in-flight flow (explicit user action).
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        browserURL = nil
        loginURL = nil
        if isBusy { phase = .idle }
    }

    private func startPolling(token: String, endpoint: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: self?.pollDeadline ?? .seconds(900))
            while !Task.isCancelled {
                if let grant = await NextcloudClient.pollLogin(token: token, endpoint: endpoint) {
                    await self?.finish(grant)
                    return
                }
                if ContinuousClock.now >= deadline {
                    await self?.timeOut()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Polling ran past its deadline without a grant. Surface a retryable error.
    private func timeOut() {
        guard case .awaitingGrant = phase else { return }
        pollTask = nil
        browserURL = nil
        loginURL = nil
        phase = .failed(GalleryError.loginFailed.userMessage)
    }

    private func finish(_ grant: (server: String, loginName: String, appPassword: String)) async {
        phase = .finishing
        browserURL = nil

        let urlBase = WebDAVPath.normalized(grant.server)
        let user = grant.loginName
        let account = AccountCredentials.makeAccount(user: user, urlBase: urlBase)

        // Register with the login name as a provisional user id, then resolve the
        // canonical user id from the profile.
        let provisional = AccountCredentials(
            account: account, urlBase: urlBase, user: user,
            userId: user, appPassword: grant.appPassword
        )
        NextcloudClient.registerSession(provisional)

        do {
            let userId = try await NextcloudClient.resolveUserId(account: account, fallback: user)
            let credentials = AccountCredentials(
                account: account, urlBase: urlBase, user: user,
                userId: userId, appPassword: grant.appPassword
            )
            phase = .idle
            onComplete?(credentials)
        } catch {
            NextcloudClient.removeSession(account)
            phase = .failed(GalleryError.loginFailed.userMessage)
        }
    }

    /// Normalizes user input into a usable https base URL, or nil if unusable.
    static func normalizedServerURL(from input: String) -> String? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty,
              components.scheme == "https" || components.scheme == "http"
        else { return nil }
        return WebDAVPath.normalized(trimmed)
    }
}

/// A URL wrapped to satisfy `Identifiable` for `.sheet(item:)`.
nonisolated struct IdentifiableURL: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}
