//
//  TabsModel.swift
//  Nextcloud Gallery
//
//  The set of open browsing tabs, which one is live, and the switcher's presented
//  state. Owns tab lifecycle (open / close / select) and persists the tab set so
//  it's restored on next launch.
//

import UIKit
import Observation

/// Manages the open ``BrowseTab``s for the signed-in session. There's always at
/// least one tab and exactly one active tab.
@Observable
@MainActor
final class TabsModel {
    private(set) var tabs: [BrowseTab]
    var activeTabID: BrowseTab.ID

    /// Whether the full-screen tab switcher is showing.
    var isShowingSwitcher = false
    /// Whether the Settings sheet is showing. Lives here so each tab's bar can
    /// open it without the carousel threading a closure through every page (which
    /// would defeat the per-frame render skipping that keeps swiping smooth).
    var isShowingSettings = false

    // Bumped to v3 when the root became Home (not the Files folder): levels gained a
    // `kind` (folder/favorites/album) and the tab dropped its `rootMode`. Older saves
    // can't decode and are dropped, leaving one fresh tab at Home on first launch.
    private static let storageKey = "openTabs.v3"

    /// The signed-in account's client, used to build a `.files` new tab's destination.
    private let client: NextcloudClient

    init(client: NextcloudClient) {
        self.client = client
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

    /// Opens a fresh tab honoring the "new tab opens to" preference and makes it
    /// active. Every option keeps Home as the tab's root level, so the user can always
    /// navigate back — including `.current`, which duplicates the active tab's whole
    /// stack (and appearance) so the new tab opens where they were with that history.
    @discardableResult
    func newTab() -> BrowseTab {
        let tab: BrowseTab
        switch NewTabDestination.preference {
        case .home:
            tab = BrowseTab()
        case .files:
            tab = BrowseTab(path: [filesRootRoute])
        case .current:
            let source = activeTab
            tab = BrowseTab(path: source.path, sort: source.sort, zoom: source.zoom, aspectFill: source.aspectFill)
        }
        tabs.append(tab)
        activeTabID = tab.id
        save()
        return tab
    }

    /// The Files-root level a `.files` new tab pushes above Home.
    private var filesRootRoute: BrowseRoute {
        .folder(path: client.filesRootPath, title: "Files", account: client.credentials.account, mode: .browse)
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
        activeTabID = id
        save()
    }

    /// Selects the next tab to the right, clamped at the last one (no wrap, to match
    /// the carousel). No-op at the boundary.
    func selectNext() {
        let i = activeIndex
        guard tabs.indices.contains(i + 1) else { return }
        activeTabID = tabs[i + 1].id
        save()
    }

    /// Selects the previous tab to the left, clamped at the first one. No-op at the
    /// boundary.
    func selectPrevious() {
        let i = activeIndex
        guard tabs.indices.contains(i - 1) else { return }
        activeTabID = tabs[i - 1].id
        save()
    }

    /// Closes every tab except `id`, which becomes the sole, active tab. No-op if `id`
    /// isn't a member.
    func closeOtherTabs(keeping id: BrowseTab.ID) {
        guard let keep = tabs.first(where: { $0.id == id }) else { return }
        tabs = [keep]
        activeTabID = keep.id
        save()
    }

    /// Opens the switcher. The live tab's card is refreshed by the carousel coordinator
    /// (which renders it content-only) as the switcher appears.
    func openSwitcher() {
        isShowingSwitcher = true
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
