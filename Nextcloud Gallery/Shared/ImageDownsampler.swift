//
//  ImageDownsampler.swift
//  Nextcloud Gallery
//
//  Downsamples image files to a target pixel size via ImageIO so the grid never
//  holds full-resolution bitmaps in memory.
//

import Foundation
import ImageIO
import CoreGraphics

nonisolated enum ImageDownsampler {
    /// A decoded, downsampled image. `CGImage` is immutable and thread-safe, so
    /// marking the wrapper `@unchecked Sendable` to cross actor boundaries is honest.
    struct Output: @unchecked Sendable {
        let cgImage: CGImage
    }

    /// Decodes and downsamples the image at `url` so its largest side is at most
    /// `maxPixels`. Pure and `nonisolated`, so callers can run it off the main
    /// actor (e.g. via `Task.detached`).
    static func downsample(url: URL, maxPixels: Int) -> Output? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return Output(cgImage: cgImage)
    }
}
