//
//  AccountCredentials.swift
//  Nextcloud Gallery
//
//  The persisted identity of the signed-in account.
//

import Foundation

/// Everything needed to talk to a Nextcloud account. Persisted (including the
/// app password) in the Keychain via ``SessionStore``.
///
/// `nonisolated` so it can move freely across actor boundaries as plain data.
nonisolated struct AccountCredentials: Sendable, Codable, Equatable {
    /// NextcloudKit's account key: `"\(user) \(urlBase)"`.
    let account: String
    /// Server base URL with no trailing slash, e.g. `https://cloud.example.com`.
    let urlBase: String
    /// The login name the user authenticated with.
    let user: String
    /// The canonical user id (may differ from `user`); used to build WebDAV paths.
    let userId: String
    /// The server-generated app password (acts as the bearer token).
    let appPassword: String

    /// Builds the account key the way the official client does.
    static func makeAccount(user: String, urlBase: String) -> String {
        "\(user) \(WebDAVPath.normalized(urlBase))"
    }
}
