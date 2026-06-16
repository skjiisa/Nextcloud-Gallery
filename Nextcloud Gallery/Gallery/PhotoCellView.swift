//
//  PhotoCellView.swift
//  Nextcloud Gallery
//
//  A single square photo cell backed by a cached thumbnail.
//

import SwiftUI

struct PhotoCellView: View {
    let item: CachedItem
    /// How the photo occupies its square slot. `.fill` crops the photo to fill the
    /// square; `.fit` shows the whole photo at its own aspect ratio, with the
    /// rounded corners clipping the photo itself (no backdrop) — like the native
    /// Photos app.
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = LayoutMetrics.tileCornerRadius

    /// Fit mode rounds the photo a touch more than fill mode rounds the square.
    private var activeCornerRadius: CGFloat {
        contentMode == .fit ? cornerRadius * 1.5 : cornerRadius
    }

    /// The photo's aspect ratio from its stored dimensions (square fallback when
    /// the server didn't report any).
    private var photoAspectRatio: CGFloat {
        item.width > 0 && item.height > 0 ? CGFloat(item.width) / CGFloat(item.height) : 1
    }

    var body: some View {
        // Outer square = the fixed grid slot. Inner `Color.clear` is the photo's
        // display rect: `slotAspectRatio` of 1 fills the square, the photo's own
        // ratio fits it within the square. Driving that one value (and animating
        // it) resizes the photo between fill and fit instead of cross-fading.
        //
        // The clip MUST sit on the definite-sized inner `Color.clear` (not on the
        // `scaledToFill` image, which is flexible and overflows) — otherwise the
        // overflow isn't cropped and photos draw over their neighbors.
        let slotAspectRatio = contentMode == .fit ? photoAspectRatio : 1
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Color.clear
                    .aspectRatio(slotAspectRatio, contentMode: .fit)
                    .overlay {
                        ThumbnailImageView(
                            ocId: item.ocId,
                            fileId: item.fileId,
                            etag: item.etag,
                            pixels: NextcloudConfig.gridThumbnailPixels
                        )
                    }
                    .clipShape(.rect(cornerRadius: activeCornerRadius))
                    .galleryTileInteraction(cornerRadius: activeCornerRadius)
            }
    }
}
