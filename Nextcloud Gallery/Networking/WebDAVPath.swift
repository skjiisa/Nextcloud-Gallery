//
//  WebDAVPath.swift
//  Nextcloud Gallery
//
//  Helpers for building and normalizing WebDAV path strings.
//

import Foundation

/// Builds and normalizes the server URL strings used as identity keys throughout
/// the cache. Centralizing this prevents an entire class of "folder shows empty
/// because the stored path had a trailing slash" predicate-mismatch bugs.
///
/// `nonisolated` so it's callable from the SwiftData actor and background pipelines.
nonisolated enum WebDAVPath {
    /// The WebDAV path of the user's Files root, e.g.
    /// `https://cloud.example.com/remote.php/dav/files/alice`.
    static func filesRoot(urlBase: String, userId: String) -> String {
        normalized(urlBase) + "/remote.php/dav/files/" + userId
    }

    /// Strips trailing slashes (the scheme's `//` is never at the end, so this is safe).
    static func normalized(_ path: String) -> String {
        var result = path
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// Joins a parent folder path with a child name.
    static func child(of parent: String, name: String) -> String {
        normalized(parent) + "/" + name
    }

    /// The display name for a folder path (its last path component).
    static func displayName(of path: String) -> String {
        normalized(path).split(separator: "/").last.map(String.init) ?? path
    }
}
