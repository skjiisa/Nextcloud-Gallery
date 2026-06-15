//
//  GalleryRootView.swift
//  Nextcloud Gallery
//
//  The signed-in experience: a navigation stack rooted at the Files root.
//

import SwiftUI

struct GalleryRootView: View {
    let client: NextcloudClient
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            FolderGridView(
                folderPath: client.filesRootPath,
                title: "Photos",
                account: client.credentials.account
            )
            .navigationDestination(for: FolderRoute.self) { route in
                FolderGridView(folderPath: route.folderPath, title: route.title, account: route.account)
            }
            .toolbar {
                if environment.warmingCoordinator?.state == .warming {
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Caching…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") {
                        showSettings = true
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .task { environment.reconcileWarming() }
        .onChange(of: scenePhase) { _, phase in
            environment.setActive(phase == .active)
        }
        .onChange(of: environment.networkMonitor.isWiFi) { _, _ in
            environment.reconcileWarming()
        }
    }
}
