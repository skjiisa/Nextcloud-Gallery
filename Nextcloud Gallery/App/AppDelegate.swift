//
//  AppDelegate.swift
//  Nextcloud Gallery
//
//  UIKit entry point. Owns the single, app-wide ``AppEnvironment`` (shared across
//  scenes so the caches, client, and warming crawl are one per process).
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// The single source of shared app state, built once at launch and shared by
    /// every scene. (Replaces the SwiftUI `@State` that lived on the old `App`.)
    let environment = AppEnvironment()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /// Reaches the shared environment from anywhere (scene delegate, etc.).
    static var shared: AppDelegate {
        // Force-unwrapped: the app delegate always exists for a UIKit app.
        UIApplication.shared.delegate as! AppDelegate
    }
}
