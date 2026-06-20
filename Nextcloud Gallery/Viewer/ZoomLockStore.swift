//
//  ZoomLockStore.swift
//  Nextcloud Gallery
//
//  Per-photo "zoom locks": when you lock a zoomed-in photo, its zoom scale and pan
//  position are remembered so reopening the photo reframes it exactly. Keyed by the
//  photo's `ocId` and persisted across launches.
//

import UIKit

/// A saved zoom + pan for one photo. `offset` is the scroll view's content offset at
/// `scale`, captured in the full-screen viewer's coordinate space.
struct ZoomLock: Codable, Equatable {
    var scale: CGFloat
    var offset: CGPoint
}

/// Holds every locked photo's framing, keyed by `ocId`. A photo only appears here
/// once its zoom is locked; unlocking removes it. Small JSON in `UserDefaults`.
@MainActor
final class ZoomLockStore {
    private var locks: [String: ZoomLock]
    private static let storageKey = "photoZoomLocks.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: ZoomLock].self, from: data) {
            locks = decoded
        } else {
            locks = [:]
        }
    }

    func lock(for ocId: String) -> ZoomLock? { locks[ocId] }
    func isLocked(_ ocId: String) -> Bool { locks[ocId] != nil }

    func setLock(_ lock: ZoomLock, for ocId: String) {
        locks[ocId] = lock
        persist()
    }

    func removeLock(for ocId: String) {
        guard locks.removeValue(forKey: ocId) != nil else { return }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(locks) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
