//
//  NextcloudClient+Albums.swift
//  Nextcloud Gallery
//
//  Reading Nextcloud Photos albums. NextcloudKit has no album API, so these talk to
//  the raw `/remote.php/dav/photos/<user>/albums/` WebDAV tree directly (a basic-auth
//  URLSession PROPFIND). That endpoint exposes each photo's file id but not its real
//  path or ocId, so an album's photos are resolved back to real `NKFile`s with a
//  files-tree WebDAV SEARCH on `oc:fileid` — making album photos first-class (true
//  originals, shared thumbnail cache, working viewer/saver) like any other photo.
//

import Foundation
import NextcloudKit

extension NextcloudClient {
    /// Root of the account's Photos albums tree.
    private var photosAlbumsRoot: String {
        WebDAVPath.normalized(credentials.urlBase) + "/remote.php/dav/photos/" + credentials.userId + "/albums/"
    }

    /// The `<d:href>` path of the albums collection itself, to skip its self entry in
    /// the PROPFIND listing.
    private var albumsRootHref: String {
        let user = credentials.userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? credentials.userId
        return "/remote.php/dav/photos/\(user)/albums/"
    }

    // MARK: - Listing albums

    /// Lists the account's Photos albums (one PROPFIND on the albums collection).
    func listAlbums() async throws -> [Album] {
        let body = """
        <?xml version="1.0"?>
        <d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
          <d:prop>
            <nc:last-photo/>
            <nc:nbItems/>
          </d:prop>
        </d:propfind>
        """
        let data = try await davRequest(method: "PROPFIND", urlString: photosAlbumsRoot, depth: "1", body: body)
        let urlBase = WebDAVPath.normalized(credentials.urlBase)
        let selfHref = albumsRootHref

        return WebDAVMultiStatus.parse(data).compactMap { entry -> Album? in
            // Drop the albums collection's own entry; keep only child albums.
            guard entry.href != selfHref else { return nil }
            let name = Self.lastPathComponent(ofHref: entry.href)
            guard !name.isEmpty else { return nil }
            let cover = entry.props["last-photo"].flatMap { $0.isEmpty ? nil : $0 }
            let count = entry.props["nbItems"].flatMap { Int($0) } ?? 0
            return Album(name: name, davPath: urlBase + entry.href, photoCount: count, coverFileId: cover)
        }
    }

    // MARK: - Album contents

    /// The photos in an album, in album order, as cache-free snapshots with real
    /// path/ocId/etag (resolved from the files tree). Two requests: one PROPFIND for
    /// the album's file ids, one batched SEARCH to resolve them.
    func albumPhotos(davPath: String) async throws -> [GridItemSnapshot] {
        let body = """
        <?xml version="1.0"?>
        <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:prop><oc:fileid/></d:prop>
        </d:propfind>
        """
        let data = try await davRequest(method: "PROPFIND", urlString: davPath, depth: "1", body: body)
        // The album collection's own entry has no file id, so it drops out here.
        let fileIds = WebDAVMultiStatus.parse(data).compactMap { entry -> String? in
            guard let id = entry.props["fileid"], !id.isEmpty else { return nil }
            return id
        }
        guard !fileIds.isEmpty else { return [] }

        let account = credentials.account
        let files = try await resolveFiles(fileIds: fileIds)
        return files.map { GridItemSnapshot(file: $0, account: account) }
    }

    /// Resolves opaque file ids to real `NKFile`s (path, ocId, etag, dimensions) via a
    /// files-tree WebDAV SEARCH, preserving the input order. Chunked so a huge album
    /// doesn't build one oversized query.
    func resolveFiles(fileIds: [String]) async throws -> [NKFile] {
        var byId: [String: NKFile] = [:]
        for chunk in fileIds.chunked(into: 200) {
            for file in try await searchFiles(byIds: chunk) {
                byId[file.fileId] = file
            }
        }
        return fileIds.compactMap { byId[$0] }
    }

    private func searchFiles(byIds ids: [String]) async throws -> [NKFile] {
        // File ids are numeric, so they need no XML escaping.
        let clauses = ids.map {
            "<d:eq><d:prop><oc:fileid/></d:prop><d:literal>\($0)</d:literal></d:eq>"
        }.joined()
        let whereClause = ids.count == 1 ? clauses : "<d:or>\(clauses)</d:or>"

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
                <d:href>/files/\(credentials.userId)</d:href>
                <d:depth>infinity</d:depth>
            </d:scope>
        </d:from>
        <d:where>\(whereClause)</d:where>
        </d:basicsearch>
        </d:searchrequest>
        """

        let result = await NextcloudKit.shared.searchBodyRequestAsync(
            serverUrl: credentials.urlBase,
            requestBody: body,
            showHiddenFiles: false,
            account: credentials.account
        )
        guard result.error == .success else { throw GalleryError(result.error) }
        return result.files ?? []
    }

    // MARK: - Raw WebDAV

    /// Issues a basic-auth WebDAV request against the photos tree (NextcloudKit can't
    /// reach it) and returns the response body.
    private func davRequest(method: String, urlString: String, depth: String, body: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw GalleryError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(NextcloudConfig.userAgent, forHTTPHeaderField: "User-Agent")
        let token = Data("\(credentials.user):\(credentials.appPassword)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GalleryError.noData }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw GalleryError.notAuthorized }
            throw GalleryError.network(code: http.statusCode, description: "WebDAV \(method) failed")
        }
        return data
    }

    /// The last (URL-decoded) path component of a WebDAV href, e.g. the album name
    /// from `/remote.php/dav/photos/u/albums/My%20Album/`.
    private static func lastPathComponent(ofHref href: String) -> String {
        let trimmed = href.hasSuffix("/") ? String(href.dropLast()) : href
        let last = trimmed.split(separator: "/").last.map(String.init) ?? ""
        return last.removingPercentEncoding ?? last
    }
}

// MARK: - WebDAV multistatus parsing

/// One `<d:response>` from a WebDAV `multistatus`: its href and a flat map of leaf
/// property local-names → text (e.g. `fileid`, `nbItems`, `last-photo`).
nonisolated struct WebDAVResponseEntry {
    let href: String
    let props: [String: String]
}

/// A minimal SAX parser for the simple album/photo PROPFINDs. Captures each
/// response's href plus the leaf text of every element inside its `<d:prop>` blocks.
/// Not-found (`404`) props come back as empty elements, so empty values are dropped
/// by callers; each requested prop appears in exactly one propstat, so status need
/// not be tracked.
private final class WebDAVMultiStatus: NSObject, XMLParserDelegate {
    static func parse(_ data: Data) -> [WebDAVResponseEntry] {
        let delegate = WebDAVMultiStatus()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.entries
    }

    private(set) var entries: [WebDAVResponseEntry] = []
    private var inResponse = false
    private var propDepth = 0
    private var currentHref: String?
    private var currentProps: [String: String] = [:]
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        text = ""
        switch elementName {
        case "response":
            inResponse = true
            propDepth = 0
            currentHref = nil
            currentProps = [:]
        case "prop":
            propDepth += 1
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "response":
            if let href = currentHref {
                entries.append(WebDAVResponseEntry(href: href, props: currentProps))
            }
            inResponse = false
            propDepth = 0
        case "prop":
            propDepth = max(0, propDepth - 1)
        case "href":
            if inResponse, propDepth == 0 { currentHref = trimmed }
        default:
            if inResponse, propDepth > 0, !trimmed.isEmpty {
                currentProps[elementName] = trimmed
            }
        }
        text = ""
    }
}

// MARK: - Utilities

private extension Array {
    /// Splits into consecutive slices of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
