//
//  AppEnvironment.swift
//  Nextcloud Gallery
//
//  Top-level shared state: who's signed in, the configured client, the caches,
//  and the warming coordinator.
//

import SwiftUI
import SwiftData
import Observation

/// The single source of shared app state, injected into the environment.
@Observable
@MainActor
final class AppEnvironment {
    let modelContainer: ModelContainer
    let cacheStore: CacheStore
    let thumbnailStore = ThumbnailStore()
    let fullImageStore = FullImageStore()
    let networkMonitor = NetworkMonitor()

    private(set) var credentials: AccountCredentials?
    private(set) var client: NextcloudClient?
    private(set) var warmingCoordinator: WarmingCoordinator?

    /// Whether the app is foreground-active; gates proactive warming.
    private var isActive = true

    var isSignedIn: Bool { credentials != nil }

    init() {
        NextcloudConfig.configure()
        let container = CacheSchema.makeContainer()
        modelContainer = container
        cacheStore = CacheStore(modelContainer: container)

        if let saved = SessionStore.load() {
            NextcloudClient.registerSession(saved)
            activate(saved)
        }

        // Bound the on-disk caches at launch (oldest evicted beyond budget).
        Task { [thumbnailStore, fullImageStore] in
            await thumbnailStore.reap(maxBytes: NextcloudConfig.thumbnailCacheBudgetBytes)
            await fullImageStore.reap(maxBytes: NextcloudConfig.fullImageCacheBudgetBytes)
        }
    }

    /// Called by the login flow once credentials are resolved.
    func completeLogin(_ credentials: AccountCredentials) {
        SessionStore.save(credentials)
        NextcloudClient.registerSession(credentials)
        activate(credentials)
    }

    /// Signs out and clears persisted credentials.
    func signOut() {
        warmingCoordinator?.pause()
        warmingCoordinator = nil
        if let account = credentials?.account {
            NextcloudClient.removeSession(account)
        }
        SessionStore.clear()
        credentials = nil
        client = nil
    }

    // MARK: - Warming control

    /// Updates foreground-active state (driven by scenePhase) and reconciles.
    func setActive(_ active: Bool) {
        isActive = active
        reconcileWarming()
    }

    /// Starts or pauses warming based on current conditions (foreground + Wi-Fi).
    func reconcileWarming() {
        guard let coordinator = warmingCoordinator else { return }
        if isActive && networkMonitor.isWiFi {
            coordinator.start()
        } else {
            coordinator.pause()
        }
    }

    private func activate(_ credentials: AccountCredentials) {
        let client = NextcloudClient(credentials: credentials)
        self.credentials = credentials
        self.client = client
        warmingCoordinator = WarmingCoordinator(
            client: client, cacheStore: cacheStore, thumbnailStore: thumbnailStore, monitor: networkMonitor
        )
        reconcileWarming()
    }
}
