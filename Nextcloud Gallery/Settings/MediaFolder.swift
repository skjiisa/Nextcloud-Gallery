//
//  MediaFolder.swift
//  Nextcloud Gallery
//
//  The user's chosen "Media folder" — the folder the Home screen's browser buttons
//  open as a gallery / folder, mirroring the official Nextcloud app's Media tab.
//  Persisted per account in UserDefaults; nil until the user sets one.
//

import Foundation

enum MediaFolder {
    /// Posted (no payload) whenever the media folder is set or cleared, so the Home
    /// browser buttons can rebuild.
    static let didChangeNotification = Notification.Name("MediaFolderDidChange")

    /// The chosen media folder's full WebDAV path for `account`, or nil if unset.
    static func path(account: String) -> String? {
        UserDefaults.standard.string(forKey: key(account))
    }

    /// Sets (or clears, with nil) the media folder for `account` and notifies observers.
    static func setPath(_ path: String?, account: String) {
        if let path {
            UserDefaults.standard.set(path, forKey: key(account))
        } else {
            UserDefaults.standard.removeObject(forKey: key(account))
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func key(_ account: String) -> String { "mediaFolder." + account }
}
