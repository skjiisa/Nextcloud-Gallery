//
//  Nextcloud_GalleryApp.swift
//  Nextcloud Gallery
//
//  Created by Elaine Lyons on 6/4/26.
//

import SwiftUI
import SwiftData

@main
struct Nextcloud_GalleryApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .modelContainer(environment.modelContainer)
        }
    }
}
