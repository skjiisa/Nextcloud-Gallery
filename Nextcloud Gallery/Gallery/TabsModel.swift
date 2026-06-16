//
//  TabsModel.swift
//  Nextcloud Gallery
//
//  The set of open browsing tabs, which one is live, and the switcher's presented
//  state. Owns tab lifecycle (open / close / select) and persists the tab set so
//  it's restored on next launch.
//

import SwiftUI

/// Manages the open ``BrowseTab``s for the signed-in session. There's always at
/// least one tab and exactly one active tab.
@Observable
@MainActor
final class TabsModel {
    private(set) var tabs: [BrowseTab]
    var activeTabID: BrowseTab.ID

    /// Whether the full-screen tab switcher is showing.
    var isShowingSwitcher = false

    private static let storageKey = "openTabs.v1"

    init() {
        let restoredTabs: [BrowseTab]
        let active: BrowseTab.ID
        if let restored = Self.loadPersisted(), !restored.tabs.isEmpty {
            restoredTabs = restored.tabs.map(BrowseTab.init(persisted:))
            // Guard against a dangling active id from a corrupt/partial save.
            active = restored.tabs.contains { $0.id == restored.activeTabID }
                ? restored.activeTabID
                : restoredTabs[0].id
        } else {
            restoredTabs = [BrowseTab()]
            active = restoredTabs[0].id
        }
        tabs = restoredTabs
        activeTabID = active
    }

    /// The live tab. Never nil — the invariant is at least one tab, with
    /// `activeTabID` always pointing at a member.
    var activeTab: BrowseTab {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    var activeIndex: Int {
        tabs.firstIndex { $0.id == activeTabID } ?? 0
    }

    // MARK: - Lifecycle

    /// Opens a fresh tab at the Files root and makes it active.
    @discardableResult
    func newTab() -> BrowseTab {
        captureActiveSnapshot()
        let tab = BrowseTab()
        tabs.append(tab)
        activeTabID = tab.id
        save()
        return tab
    }

    /// Opens `route` (a folder or flattened gallery) in a new background-free tab
    /// and switches to it — the current tab keeps its place. Used by the folder
    /// "Open in New Tab" action.
    func open(_ route: BrowseRoute, inNewTab: Bool) {
        if inNewTab {
            let tab = BrowseTab(path: [route])
            tabs.append(tab)
            activeTabID = tab.id
            save()
        } else {
            activeTab.path.append(route)
        }
    }

    /// Closes a tab. Closing the active one selects a sensible neighbour; closing
    /// the last tab leaves a fresh empty tab behind (à la Safari).
    func closeTab(_ id: BrowseTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == activeTabID
        tabs.remove(at: index)

        if tabs.isEmpty {
            let fresh = BrowseTab()
            tabs = [fresh]
            activeTabID = fresh.id
        } else if wasActive {
            // Prefer the tab that shifted into this slot, else the new last one.
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        save()
    }

    func select(_ id: BrowseTab.ID) {
        guard id != activeTabID, tabs.contains(where: { $0.id == id }) else { return }
        captureActiveSnapshot()
        activeTabID = id
        save()
    }

    /// Switches to the tab `offset` positions away (e.g. -1 / +1 for the bottom
    /// bar's swipe-between-tabs gesture), clamped to the ends.
    func selectRelative(_ offset: Int) {
        let target = activeIndex + offset
        guard tabs.indices.contains(target), target != activeIndex else { return }
        captureActiveSnapshot()
        activeTabID = tabs[target].id
        save()
    }

    /// Opens the switcher, first refreshing the live tab's card so it shows what
    /// the user was just looking at.
    func openSwitcher() {
        captureActiveSnapshot()
        isShowingSwitcher = true
    }

    /// Grabs a thumbnail of the on-screen (live) tab for its switcher card.
    private func captureActiveSnapshot() {
        activeTab.snapshot = WindowSnapshot.capture()
    }

    // MARK: - Persistence

    private nonisolated struct Persisted: Codable {
        var tabs: [BrowseTab.Persisted]
        var activeTabID: UUID
    }

    /// Serializes the tab set. Cheap; called on structural changes and when the
    /// app backgrounds (to capture in-tab navigation that happened since).
    func save() {
        let snapshot = Persisted(tabs: tabs.map(\.persisted), activeTabID: activeTabID)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func loadPersisted() -> Persisted? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data)
    }
}
