//
//  PhotoPageView.swift
//  Nextcloud Gallery
//
//  One page of the photo viewer: a progressively-loaded, zoomable image.
//

import SwiftUI

struct PhotoPageView: View {
    let photo: PhotoItem
    @Binding var isZoomed: Bool

    @Environment(AppEnvironment.self) private var environment
    @State private var loader = PhotoLoader()

    var body: some View {
        ZStack {
            if loader.image == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
            ZoomableImageView(image: loader.image, isZoomed: $isZoomed)
        }
        .task(id: photo.id) {
            await loader.load(photo: photo, environment: environment)
        }
    }
}
