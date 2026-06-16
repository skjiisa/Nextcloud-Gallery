//
//  TabbedGalleryView.swift
//  Nextcloud Gallery
//
//  The signed-in experience. Shows one browsing tab at a time — its own
//  navigation stack rooted at the Files root — beneath a persistent bottom bar,
//  and hosts the tab switcher. Also owns the session-level concerns that used to
//  live on the single root stack: warming lifecycle and tab persistence.
//

import SwiftUI

struct TabbedGalleryView: View {
    let client: NextcloudClient

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    @State private var tabs = TabsModel()
    @State private var showSettings = false

    var body: some View {
        @Bindable var tabs = tabs

        // Only the live tab is rendered; `.id` rebuilds the stack on a tab switch
        // so each tab restores its own path, appearance, and open viewer cleanly.
        TabContentView(tab: tabs.activeTab, client: client)
            .id(tabs.activeTabID)
            .environment(tabs)
            .safeAreaInset(edge: .bottom) {
                TabBarView(onShowSettings: { showSettings = true })
                    .environment(tabs)
            }
            // Present the switcher from here only while browsing. When a photo is
            // open, the viewer is the top-most cover and presents the switcher
            // itself (see PhotoViewerView) — two covers can't stack from sibling
            // hosts, so we gate this one on there being no open viewer.
            .fullScreenCover(isPresented: browseSwitcherBinding) {
                TabSwitcherView()
                    .environment(tabs)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .task { environment.reconcileWarming() }
            .onChange(of: scenePhase) { _, phase in
                environment.setActive(phase == .active)
                // Capture in-tab navigation that happened since the last structural
                // change, so a relaunch restores where each tab was parked.
                if phase != .active { tabs.save() }
            }
            .onChange(of: environment.networkMonitor.isWiFi) { _, _ in
                environment.reconcileWarming()
            }
    }

    /// The switcher binding for the browse context: live only when no viewer is
    /// open, so it never competes with the viewer's own switcher presentation.
    private var browseSwitcherBinding: Binding<Bool> {
        Binding(
            get: { tabs.isShowingSwitcher && tabs.activeTab.viewer == nil },
            set: { tabs.isShowingSwitcher = $0 }
        )
    }
}

/// Renders one tab: its navigation stack and the full-screen photo viewer it may
/// have open. Split out so the active `BrowseTab` can be `@Bindable` here and
/// supplied to descendants through the environment.
private struct TabContentView: View {
    @Bindable var tab: BrowseTab
    let client: NextcloudClient

    var body: some View {
        NavigationStack(path: $tab.path) {
            FolderGridView(
                folderPath: client.filesRootPath,
                title: "Photos",
                account: client.credentials.account
            )
            .navigationDestination(for: BrowseRoute.self) { route in
                switch route {
                case .folder(let route):
                    FolderGridView(folderPath: route.folderPath, title: route.title, account: route.account)
                case .flat(let route):
                    FlatGalleryView(folderPath: route.folderPath, title: route.title, account: route.account)
                }
            }
        }
        // The tab carries this BrowseTab to every screen it pushes, so a deep
        // folder/gallery can open the viewer or read this tab's appearance.
        .environment(tab)
        .fullScreenCover(item: $tab.viewer) { presentation in
            PhotoViewerView(photos: presentation.photos, initialPhotoID: presentation.initialID)
        }
    }
}
