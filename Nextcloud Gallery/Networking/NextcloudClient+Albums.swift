//
//  NextcloudClient+Albums.swift
//  Nextcloud Gallery
//
//  Nextcloud Photos albums (and system-tag lookups that share the same fileId
//  resolve). Album reads/writes go through NextcloudKit's album API (7.6+), which
//  wraps the Photos app's `/remote.php/dav/photos/<user>/albums/` WebDAV tree.
//
//  That tree exposes each photo's file id but not its real path or ocId, so an
//  album's photos are resolved back to real `NKFile`s with one batched files-tree
//  WebDAV SEARCH on `oc:fileid` — making album photos first-class (true originals,
//  shared thumbnail cache, working viewer/saver) like any other photo. (The official
//  app instead resolves each uncached photo with its own request.)
//

import Foundation
import NextcloudKit

/// An album's photos plus the name each one has *inside* the album collection
/// (`{fileId}-{fileName}` on the Photos backend), which is what removal targets.
nonisolated struct AlbumContents: Sendable {
    let photos: [GridItemSnapshot]
    /// File id → the photo's entry name in the album collection.
    let entryNames: [String: String]
}

extension NextcloudClient {
    // MARK: - Albums

    /// Lists the account's Photos albums.
    func listAlbums() async throws -> [Album] {
        let account = credentials.account
        let albums: [NKPhotoAlbum] = try await nkResult {
            NextcloudKit.shared.fetchAllAlbums(for: account, completion: $0)
        }
        return albums.map {
            Album(name: $0.name, photoCount: $0.itemCount ?? 0, coverFileId: $0.lastPhotoId.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// The photos in an album, in album order, as cache-free snapshots with real
    /// path/ocId/etag (resolved from the files tree), plus each photo's entry name in
    /// the album. Two requests: the album PROPFIND, then one batched SEARCH.
    func albumContents(named albumName: String) async throws -> AlbumContents {
        let account = credentials.account
        let entries: [NKFile] = try await nkResult {
            NextcloudKit.shared.fetchAlbumPhotos(for: albumName, account: account, completion: $0)
        }
        // The album collection's own entry is a directory with no file id.
        var entryNames: [String: String] = [:]
        var fileIds: [String] = []
        for entry in entries where !entry.directory && !entry.fileId.isEmpty {
            guard entryNames[entry.fileId] == nil else { continue }
            entryNames[entry.fileId] = entry.fileName
            fileIds.append(entry.fileId)
        }
        guard !fileIds.isEmpty else { return AlbumContents(photos: [], entryNames: [:]) }

        let photos = try await resolveFiles(fileIds: fileIds).map { GridItemSnapshot(file: $0, account: account) }
        return AlbumContents(photos: photos, entryNames: entryNames)
    }

    /// Creates a new, empty album.
    func createAlbum(named name: String) async throws {
        let account = credentials.account
        _ = try await nkResult { NextcloudKit.shared.createNewAlbum(for: account, albumName: name, completion: $0) }
    }

    /// Renames an album. Fails (rather than overwriting) if `newName` is taken.
    func renameAlbum(named name: String, to newName: String) async throws {
        let account = credentials.account
        _ = try await nkResult { NextcloudKit.shared.renameAlbum(account: account, from: name, to: newName, completion: $0) }
    }

    /// Deletes an album. Its photos are untouched — membership is only a reference.
    func deleteAlbum(named name: String) async throws {
        let account = credentials.account
        _ = try await nkResult { NextcloudKit.shared.deleteAlbum(albumName: name, account: account, completion: $0) }
    }

    /// Adds the photo at `photoServerPath` (a full Files-DAV URL) to an album. The
    /// Photos backend models membership as a COPY into the album collection — a
    /// virtual reference, not a second copy of the bytes. A 409 means it's already
    /// there, which is treated as success.
    func addToAlbum(named albumName: String, photoServerPath: String, fileName: String) async throws {
        let account = credentials.account
        do {
            _ = try await nkResult {
                NextcloudKit.shared.copyPhotoToAlbum(
                    account: account, sourcePath: photoServerPath, albumName: albumName, fileName: fileName, completion: $0
                )
            }
        } catch GalleryError.network(code: 409, _) {
            // Already in the album.
        }
    }

    /// Removes one photo from an album (the real file is untouched). `entryName` is
    /// the photo's name inside the album collection — see ``AlbumContents``.
    func removeFromAlbum(named albumName: String, entryName: String) async throws {
        do {
            try await NextcloudKit.shared.deletePhotoFromAlbumAsync(albumName: albumName, fileName: entryName, account: credentials.account)
        } catch let error as NKError {
            throw GalleryError(error)
        }
    }

    /// Bridges a NextcloudKit completion-handler call to async/await, translating
    /// its `NKError` into a ``GalleryError``.
    private func nkResult<T: Sendable>(_ call: (@escaping (Result<T, NKError>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            call { continuation.resume(with: $0.mapError(GalleryError.init)) }
        }
    }

    // MARK: - Resolving file ids

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

    // MARK: - Tagged files

    /// All image files carrying the system tag `tagId`, as cache-free snapshots. A
    /// `filter-files` REPORT lists the tagged file ids, which are resolved to real
    /// `NKFile`s the same way album photos are (so the viewer/saver work on them).
    func taggedFiles(tagId: String) async throws -> [GridItemSnapshot] {
        let body = """
        <?xml version="1.0"?>
        <oc:filter-files xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
          <d:prop><oc:fileid/></d:prop>
          <oc:filter-rules><oc:systemtag>\(tagId)</oc:systemtag></oc:filter-rules>
        </oc:filter-files>
        """
        let data = try await davRequest(method: "REPORT", urlString: WebDAVPath.normalized(filesRootPath) + "/", body: body)
        let fileIds = WebDAVMultiStatus.parse(data).compactMap { entry -> String? in
            guard let id = entry.props["fileid"], !id.isEmpty else { return nil }
            return id
        }
        guard !fileIds.isEmpty else { return [] }

        let account = credentials.account
        return try await resolveFiles(fileIds: fileIds)
            .filter { !$0.directory && $0.hasPreview && $0.classFile == NKTypeClassFile.image.rawValue }
            .map { GridItemSnapshot(file: $0, account: account) }
    }

    /// The file id of a representative image carrying the tag, for a cover thumbnail —
    /// the first image in the `filter-files` REPORT (no resolve needed; preview-by-id
    /// only needs the file id).
    func tagCoverFileId(tagId: String) async throws -> String? {
        let body = """
        <?xml version="1.0"?>
        <oc:filter-files xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
          <d:prop><oc:fileid/><d:getcontenttype/></d:prop>
          <oc:filter-rules><oc:systemtag>\(tagId)</oc:systemtag></oc:filter-rules>
        </oc:filter-files>
        """
        let data = try await davRequest(method: "REPORT", urlString: WebDAVPath.normalized(filesRootPath) + "/", body: body)
        for entry in WebDAVMultiStatus.parse(data) {
            guard let id = entry.props["fileid"], !id.isEmpty else { continue }
            if (entry.props["getcontenttype"] ?? "").hasPrefix("image/") { return id }
        }
        return nil
    }

    // MARK: - Raw WebDAV

    /// Issues a basic-auth WebDAV request (the system-tag `filter-files` REPORTs,
    /// which NextcloudKit doesn't wrap) and returns the response body. `depth`/`body`
    /// are optional.
    private func davRequest(method: String, urlString: String, depth: String? = nil, body: String? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw GalleryError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let depth { request.setValue(depth, forHTTPHeaderField: "Depth") }
        request.setValue(NextcloudConfig.userAgent, forHTTPHeaderField: "User-Agent")
        let token = Data("\(credentials.user):\(credentials.appPassword)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.data(using: .utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GalleryError.noData }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw GalleryError.notAuthorized }
            throw GalleryError.network(code: http.statusCode, description: "WebDAV \(method) failed")
        }
        return data
    }
}

// MARK: - WebDAV multistatus parsing

/// One `<d:response>` from a WebDAV `multistatus`: its href and a flat map of leaf
/// property local-names → text (e.g. `fileid`, `nbItems`, `last-photo`).
nonisolated struct WebDAVResponseEntry {
    let href: String
    let props: [String: String]
}

/// A minimal SAX parser for the simple tag REPORTs. Captures each
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
