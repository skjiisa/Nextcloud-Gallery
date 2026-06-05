//
//  ThumbnailImageView.swift
//  Nextcloud Gallery
//
//  Loads and displays a single cached thumbnail, with a placeholder and crossfade.
//

import SwiftUI

/// Renders a thumbnail for a cached photo. Fetches via ``ThumbnailStore``,
/// downsamples off the main actor, and crossfades the result in. Re-loads if the
/// item's etag changes.
struct ThumbnailImageView: View {
    let ocId: String
    let fileId: String
    let etag: String
    let pixels: Int

    @Environment(AppEnvironment.self) private var environment
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task(id: ThumbKey(ocId: ocId, etag: etag, pixels: pixels).id) {
            await load()
        }
    }

    private func load() async {
        guard let client = environment.client else { return }
        do {
            let url = try await environment.thumbnailStore.load(
                ocId: ocId, fileId: fileId, etag: etag, pixels: pixels, client: client
            )
            // Decode + downsample off the main actor.
            let maxPixels = pixels
            let output = await Task.detached(priority: .utility) {
                ImageDownsampler.downsample(url: url, maxPixels: maxPixels)
            }.value
            guard let output else { return }
            withAnimation(.easeIn(duration: 0.15)) {
                image = Image(decorative: output.cgImage, scale: 1)
            }
        } catch {
            // Leave the placeholder in place.
        }
    }
}
