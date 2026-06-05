//
//  CacheSchema.swift
//  Nextcloud Gallery
//
//  Builds the shared SwiftData ModelContainer for the on-disk cache.
//

import Foundation
import SwiftData

/// Owns the cache schema and constructs the shared `ModelContainer`.
///
/// The cache is disposable (everything can be re-crawled), so if the on-disk
/// store can't be opened we wipe it and retry, falling back to in-memory.
nonisolated enum CacheSchema {
    static let models: [any PersistentModel.Type] = [CachedItem.self, FolderState.self]

    static func makeContainer() -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return container
        }

        // Incompatible/corrupt store: discard it and retry once.
        wipeStoreFiles()
        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return container
        }

        // Last resort so the app still runs (truly unrecoverable otherwise).
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: [memory])
    }

    private static func wipeStoreFiles() {
        let base = URL.applicationSupportDirectory
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            try? FileManager.default.removeItem(at: base.appending(path: name))
        }
    }
}
