//
//  TabbedGalleryView.swift
//  Nextcloud Gallery
//
//  The signed-in experience. Hosts the swipeable tab carousel (one navigation
//  stack + toolbar per tab) and the tab switcher, and owns the session-level
//  concerns that used to live on the single root stack: warming lifecycle and
//  tab persistence.
//

import SwiftUI

struct TabbedGalleryView: View {
    let client: NextcloudClient

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    @State private var tabs = TabsModel()

    var body: some View {
        @Bindable var tabs = tabs

        // The tabs laid out as a swipeable carousel; each page carries its own
        // navigation stack and bottom bar (see TabCarouselView).
        TabCarouselView(client: client)
            .environment(tabs)
            // Present the switcher from here only while browsing. When a photo is
            // open, the viewer is the top-most cover and presents the switcher
            // itself (see PhotoViewerView) — two covers can't stack from sibling
            // hosts, so we gate this one on there being no open viewer.
            .fullScreenCover(isPresented: browseSwitcherBinding) {
                TabSwitcherView()
                    .environment(tabs)
            }
            .sheet(isPresented: $tabs.isShowingSettings) {
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
