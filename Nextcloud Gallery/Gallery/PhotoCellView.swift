//
//  PhotoCellView.swift
//  Nextcloud Gallery
//
//  A single square photo cell backed by a cached thumbnail.
//

import SwiftUI

struct PhotoCellView: View {
    let item: CachedItem

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ThumbnailImageView(
                    ocId: item.ocId,
                    fileId: item.fileId,
                    etag: item.etag,
                    pixels: NextcloudConfig.gridThumbnailPixels
                )
            }
            .clipShape(.rect(cornerRadius: LayoutMetrics.tileCornerRadius))
            .galleryTileInteraction()
    }
}
