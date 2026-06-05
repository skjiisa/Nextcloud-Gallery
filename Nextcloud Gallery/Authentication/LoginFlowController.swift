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

    var isBusy: Bool {
        switch phase {
        case .starting, .awaitingGrant, .finishing: true
        case .idle, .failed: false
        }
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

        browserURL = IdentifiableURL(url: begin.login)
        phase = .awaitingGrant
        startPolling(token: begin.token, endpoint: begin.endpoint)
    }

    /// Cancels an in-flight flow (e.g. the user dismissed the browser).
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        browserURL = nil
        if isBusy { phase = .idle }
    }

    private func startPolling(token: String, endpoint: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let grant = await NextcloudClient.pollLogin(token: token, endpoint: endpoint) {
                    await self?.finish(grant)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
