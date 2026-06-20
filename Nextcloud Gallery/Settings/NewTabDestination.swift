//
//  NewTabDestination.swift
//  Nextcloud Gallery
//
//  User preference for what a freshly opened tab shows (the bottom bar / switcher /
//  viewer "+" button). Persisted in UserDefaults and read by ``TabsModel/newTab()``.
//

import Foundation

/// Where a new tab opens. Every option keeps Home as the tab's root level, so a new
/// tab always has a navigation stack the user can back out through.
nonisolated enum NewTabDestination: String, CaseIterable, Sendable {
    /// The Home hub (default).
    case home
    /// The Files root folder, pushed above Home (Home → Files).
    case files
    /// A copy of the current tab's navigation stack — "wherever you already are".
    case current

    var label: String {
        switch self {
        case .home: "Home"
        case .files: "Files"
        case .current: "Current Location"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .files: "folder"
        case .current: "location"
        }
    }

    // MARK: - Persistence

    private static let storageKey = "newTabDestination"

    /// The stored preference, defaulting to ``home``.
    static var preference: NewTabDestination {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(NewTabDestination.init(rawValue:)) ?? .home }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}
