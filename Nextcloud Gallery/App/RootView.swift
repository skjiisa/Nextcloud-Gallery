//
//  RootView.swift
//  Nextcloud Gallery
//
//  Switches between the login screen and the signed-in gallery.
//

import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if environment.isSignedIn, let client = environment.client {
                GalleryRootView(client: client)
            } else {
                LoginView()
            }
        }
        // Derive layout metrics once from the window's size class and inject them
        // for the whole tree; descendants read them via `@Environment(\.layoutMetrics)`.
        .environment(\.layoutMetrics, LayoutMetrics(sizeClass: horizontalSizeClass))
    }
}
