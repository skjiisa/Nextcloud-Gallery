//
//  PhotoLoader.swift
//  Nextcloud Gallery
//
//  Progressive image loading for the viewer: cached thumb → preview → full file.
//

import SwiftUI
import Observation

/// Loads the displayed image for one photo in stages so something appears
/// instantly and sharpens up. Decoding happens off the main actor.
@Observable
@MainActor
final class PhotoLoader {
    private(set) var image: UIImage?

    /// Largest side we decode the full file to — caps memory while staying sharp
    /// well past typical screen sizes.
    private let fullImageMaxPixels = 4096

    func load(photo: PhotoItem, environment: AppEnvironment) async {
        guard let client = environment.client else { return }

        // Stage 1: an already-cached grid thumbnail, if present (instant).
        if image == nil,
           let url = await environment.thumbnailStore.cachedURL(
                ocId: photo.ocId, etag: photo.etag, pixels: NextcloudConfig.gridThumbnailPixels) {
            await setImage(from: url, maxPixels: NextcloudConfig.gridThumbnailPixels)
        }
        if Task.isCancelled { return }

        // Stage 2: a larger preview (fast, server-rendered).
        if let url = try? await environment.thumbnailStore.load(
            ocId: photo.ocId, fileId: photo.fileId, etag: photo.etag,
            pixels: NextcloudConfig.viewerPreviewPixels, client: client) {
            await setImage(from: url, maxPixels: NextcloudConfig.viewerPreviewPixels)
        }
        if Task.isCancelled { return }

        // Stage 3: the original file for crisp zooming.
        if let url = try? await environment.fullImageStore.load(
            ocId: photo.ocId, etag: photo.etag, fileName: photo.fileName,
            serverPath: photo.serverPath, client: client) {
            await setImage(from: url, maxPixels: fullImageMaxPixels)
        }
    }

    private func setImage(from url: URL, maxPixels: Int) async {
        let output = await Task.detached(priority: .userInitiated) {
            ImageDownsampler.downsample(url: url, maxPixels: maxPixels)
        }.value
        guard let output, !Task.isCancelled else { return }
        image = UIImage(cgImage: output.cgImage)
    }
}
