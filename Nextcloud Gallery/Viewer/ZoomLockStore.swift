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
/// `scale`, captured in the full-screen viewer's coordinate space. `crop` is the region
/// of the image that's visible at that framing, normalized to 0...1 in the image's own
/// pixel space (top-left origin) — it's what the grid renders so a locked photo shows
/// its locked framing as a tile, and what the open/close hero grows. Nil for locks
/// saved before crops were stored (those fall back to the whole image).
struct ZoomLock: Codable, Equatable {
    var scale: CGFloat
    var offset: CGPoint
    var crop: CGRect?

    /// The locked crop's aspect ratio for an image of `imageAspect` (width / height),
    /// or the plain image aspect when there's no crop. The grid sizes a locked tile to
    /// this — effectively the viewer viewport's (portrait) shape.
    func tileAspect(imageAspect: CGFloat) -> CGFloat {
        guard let crop, crop.width > 0, crop.height > 0 else { return imageAspect }
        return imageAspect * (crop.width / crop.height)
    }

    /// The cache resolution for this lock's cropped tile: scale the base grid size up by
    /// how far the lock zooms in (the crop's smaller normalized side), then snap to the
    /// next rung of ``NextcloudConfig/lockedThumbnailPixelLadder``. Deterministic from
    /// `crop`, so warming a saved lock and evicting a cleared one address the same file.
    /// Returns the grid size (the floor) when unlocked or barely zoomed.
    var thumbnailPixels: Int {
        guard let crop, crop.width > 0, crop.height > 0 else { return NextcloudConfig.gridThumbnailPixels }
        let target = CGFloat(NextcloudConfig.gridThumbnailPixels) / min(crop.width, crop.height)
        let ladder = NextcloudConfig.lockedThumbnailPixelLadder
        return ladder.first { CGFloat($0) >= target } ?? ladder.last ?? NextcloudConfig.gridThumbnailPixels
    }
}

extension UIImage {
    /// The sub-image for `rect` (normalized 0...1, top-left origin in the image's own
    /// orientation) — used to render a zoom-locked photo's visible crop in the grid and
    /// its open/close hero. Returns self when the rect is the whole image or cropping
    /// fails. Images here are always `.up`/scale-1 (`UIImage(cgImage:)`), so a pixel
    /// crop maps 1:1.
    func croppedToNormalized(_ rect: CGRect) -> UIImage {
        guard let cg = cgImage,
              rect.minX > 0.001 || rect.minY > 0.001 || rect.width < 0.999 || rect.height < 0.999
        else { return self }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let pixelRect = CGRect(x: rect.minX * w, y: rect.minY * h,
                               width: rect.width * w, height: rect.height * h).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1, let cropped = cg.cropping(to: pixelRect) else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}

/// Holds every locked photo's framing, keyed by `ocId`. A photo only appears here
/// once its zoom is locked; unlocking removes it. Small JSON in `UserDefaults`.
@MainActor
final class ZoomLockStore {
    private var locks: [String: ZoomLock]
    private static let storageKey = "photoZoomLocks.v2"

    /// Posted when a photo's lock is set or cleared, so open grids can re-render that
    /// tile's framing. The `ocId` is in `userInfo["ocId"]`.
    static let didChange = Notification.Name("ZoomLockStoreDidChange")

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
        notifyChange(ocId)
    }

    func removeLock(for ocId: String) {
        guard locks.removeValue(forKey: ocId) != nil else { return }
        persist()
        notifyChange(ocId)
    }

    private func notifyChange(_ ocId: String) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["ocId": ocId])
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(locks) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
