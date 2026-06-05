//
//  RootView.swift
//  Nextcloud Gallery
//
//  Switches between the login screen and the signed-in gallery.
//

import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if environment.isSignedIn, let client = environment.client {
            GalleryRootView(client: client)
        } else {
            LoginView()
        }
    }
}
