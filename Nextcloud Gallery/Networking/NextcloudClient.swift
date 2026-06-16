//
//  NextcloudClient.swift
//  Nextcloud Gallery
//
//  The single point of contact with NextcloudKit. Everything else in the app
//  talks to the server through this type, so a future change to NextcloudKit
//  (or its `shared` singleton, which only exists under Swift < 6 language mode)
//  is contained here.
//

import Foundation
import NextcloudKit
import Alamofire

/// A configured, per-account gateway to the Nextcloud server.
///
/// `nonisolated` (the project defaults to `@MainActor` isolation) so it can be
/// called from background actors — the warming crawler and thumbnail pipeline.
/// All stored state is immutable `Sendable` data.
nonisolated final class NextcloudClient: Sendable {
    let credentials: AccountCredentials

    init(credentials: AccountCredentials) {
        self.credentials = credentials
    }

    /// The WebDAV path of this account's Files root.
    var filesRootPath: String {
        WebDAVPath.filesRoot(urlBase: credentials.urlBase, userId: credentials.userId)
    }

    // MARK: - Listing

    /// Lists the immediate children of a folder (depth 1). The folder itself is
    /// dropped from the result. Pass a background `queue` for proactive crawling
    /// so PROPFIND parsing doesn't run on the main thread.
    func listFolder(
        at path: String,
        queue: DispatchQueue = .main
    ) async throws -> [NKFile] {
        let options = NKRequestOptions(queue: queue)
        let result = await NextcloudKit.shared.readFileOrFolderAsync(
            serverUrlFileName: path,
            depth: "1",
            account: credentials.account,
            options: options
        )
        guard result.error == .success else { throw GalleryError(result.error) }
        guard var files = result.files else { throw GalleryError.noData }

        // The first element is the folder itself; remove it by matching its path,
        // falling back to dropping the first entry.
        let target = WebDAVPath.normalized(path)
        if let index = files.firstIndex(where: {
            WebDAVPath.normalized($0.serverUrl + "/" + $0.fileName) == target
        }) {
            files.remove(at: index)
        } else if !files.isEmpty {
            files.removeFirst()
        }
        return files
    }

    // MARK: - Media search

    /// Recursively searches a folder's subtree for image files, newest first, and
    /// returns the raw server entries. Mirrors the official app's gallery tab: a
    /// WebDAV SEARCH scoped to the folder with `depth: infinity`, ordered by last
    /// modified descending. Pass a background `queue` so XML parsing stays off the
    /// main thread.
    func searchMedia(
        under folderPath: String,
        limit: Int = NextcloudConfig.mediaSearchLimit,
        queue: DispatchQueue = .main
    ) async throws -> [NKFile] {
        // The SEARCH endpoint lives at `urlBase + "/remote.php/dav"`; the scope
        // `href` is the DAV-root-relative path, i.e. "/files/<userId>/<subpath>".
        let root = WebDAVPath.normalized(filesRootPath)
        let normalized = WebDAVPath.normalized(folderPath)
        let subPath = normalized.hasPrefix(root) ? String(normalized.dropFirst(root.count)) : ""
        let href = Self.xmlEscaped("/files/" + credentials.userId + subPath)

        let body = """
        <?xml version="1.0"?>
        <d:searchrequest xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
        <d:basicsearch>
        <d:select>
            <d:prop>
        \(NKProperties.properties(createProperties: nil))
            </d:prop>
        </d:select>
        <d:from>
            <d:scope>
                <d:href>\(href)</d:href>
                <d:depth>infinity</d:depth>
            </d:scope>
        </d:from>
        <d:orderby>
            <d:order>
                <d:prop><d:getlastmodified/></d:prop>
                <d:descending/>
            </d:order>
            <d:order>
                <d:prop><d:displayname/></d:prop>
                <d:descending/>
            </d:order>
        </d:orderby>
        <d:where>
            <d:like>
                <d:prop><d:getcontenttype/></d:prop>
                <d:literal>image/%</d:literal>
            </d:like>
        </d:where>
        <d:limit>
            <d:nresults>\(limit)</d:nresults>
        </d:limit>
        </d:basicsearch>
        </d:searchrequest>
        """

        let options = NKRequestOptions(queue: queue)
        let result = await NextcloudKit.shared.searchBodyRequestAsync(
            serverUrl: credentials.urlBase,
            requestBody: body,
            showHiddenFiles: false,
            account: credentials.account,
            options: options
        )
        guard result.error == .success else { throw GalleryError(result.error) }
        return result.files ?? []
    }

    /// Minimal XML text escaping for a path interpolated into the SEARCH body.
    private static func xmlEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Thumbnails

    /// Downloads a server preview for an item and returns the JPEG bytes. Only
    /// valid for items whose `hasPreview` is true. Uses NextcloudKit's default
    /// `crop: 1` — which on Nextcloud means *keep aspect ratio* (the preview fits
    /// within `pixels`, it is not square-cropped), so callers can show it either
    /// cropped (`scaledToFill`) or letterboxed (`scaledToFit`) client-side.
    func downloadPreview(
        fileId: String,
        etag: String,
        pixels: Int,
        queue: DispatchQueue = .main
    ) async throws -> Data {
        let options = NKRequestOptions(queue: queue)
        let result = await NextcloudKit.shared.downloadPreviewAsync(
            fileId: fileId,
            width: pixels,
            height: pixels,
            etag: etag,
            account: credentials.account,
            options: options
        )
        guard result.error == .success else { throw GalleryError(result.error) }
        guard let data = result.responseData?.data else { throw GalleryError.noData }
        return data
    }

    // MARK: - Full file download

    /// Downloads the original file to a local path (creates intermediate dirs and
    /// replaces any existing file).
    func downloadFile(
        serverPath: String,
        toPath localPath: String,
        queue: DispatchQueue = .main
    ) async throws {
        let options = NKRequestOptions(queue: queue)
        let result = await NextcloudKit.shared.downloadAsync(
            serverUrlFileName: serverPath,
            fileNameLocalPath: localPath,
            account: credentials.account,
            options: options
        )
        guard result.nkError == .success else { throw GalleryError(result.nkError) }
    }

    // MARK: - Login flow v2

    /// Step 1 of web login: ask the server for a login URL + poll token.
    static func beginLogin(serverURL: String) async throws -> (login: URL, endpoint: String, token: String) {
        let options = NKRequestOptions(customUserAgent: NextcloudConfig.userAgent)
        do {
            let result = try await NextcloudKit.shared.getLoginFlowV2(serverUrl: serverURL, options: options)
            return (login: result.login, endpoint: result.endpoint.absoluteString, token: result.token)
        } catch {
            throw GalleryError.loginFailed
        }
    }

    /// Step 2 of web login: one poll attempt. Returns the granted credentials
    /// once the user approves access in the browser, otherwise `nil`.
    static func pollLogin(
        token: String,
        endpoint: String
    ) async -> (server: String, loginName: String, appPassword: String)? {
        let options = NKRequestOptions(customUserAgent: NextcloudConfig.userAgent)
        let result = await NextcloudKit.shared.getLoginFlowV2PollAsync(
            token: token,
            endpoint: endpoint,
            options: options
        )
        guard result.error == .success,
              let server = result.server,
              let loginName = result.loginName,
              let appPassword = result.appPassword
        else { return nil }
        return (server: server, loginName: loginName, appPassword: appPassword)
    }

    // MARK: - Session lifecycle

    /// Registers (or updates) the NextcloudKit session for an account. Idempotent.
    static func registerSession(_ credentials: AccountCredentials) {
        NextcloudKit.shared.appendSession(
            account: credentials.account,
            urlBase: credentials.urlBase,
            user: credentials.user,
            userId: credentials.userId,
            password: credentials.appPassword,
            userAgent: NextcloudConfig.userAgent,
            httpMaximumConnectionsPerHost: NextcloudConfig.httpMaximumConnectionsPerHost,
            groupIdentifier: NextcloudConfig.groupIdentifier
        )
    }

    /// Fetches the canonical user id for an account and updates the session with it.
    /// Returns the resolved user id (the login name may differ from the user id).
    static func resolveUserId(account: String, fallback: String) async throws -> String {
        let result = await NextcloudKit.shared.getUserProfileAsync(account: account)
        guard result.error == .success, let profile = result.userProfile else {
            throw GalleryError(result.error)
        }
        // NKUserProfile is a non-Sendable class — extract the value immediately.
        let userId = profile.userId
        NextcloudKit.shared.updateSession(account: account, userId: userId)
        return userId.isEmpty ? fallback : userId
    }

    /// Tears down a NextcloudKit session (used on sign out).
    static func removeSession(_ account: String) {
        NextcloudKit.shared.nkCommonInstance.nksessions.remove(account: account)
        NextcloudKit.shared.deleteCookieStorageForAccount(account)
    }
}
