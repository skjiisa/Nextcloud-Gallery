//
//  SceneDelegate.swift
//  Nextcloud Gallery
//
//  Owns one window. Chooses the root (login vs the tabbed gallery) from the shared
//  environment's sign-in state and swaps it live when the user signs in or out.
//  Maps scene activation to warming control (foreground-active gates the crawl).
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// The open browsing tabs for this window. Created on sign-in and kept for the
    /// scene's lifetime; persisted to (shared) UserDefaults so it restores at launch.
    private var tabs: TabsModel?
    private var signInObservation: ObservationToken?

    private var environment: AppEnvironment { AppDelegate.shared.environment }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        window.makeKeyAndVisible()

        // Swap the root whenever sign-in state flips (login completes / sign out).
        signInObservation = observeChanges { [weak self] in
            self?.updateRoot(animated: self?.window?.rootViewController != nil)
        }
    }

    /// Installs the correct root for the current sign-in state, reusing the existing
    /// root if it's already the right kind.
    private func updateRoot(animated: Bool) {
        guard let window else { return }
        let signedIn = environment.isSignedIn

        if signedIn, let client = environment.client {
            if window.rootViewController is RootCarouselViewController { return }
            let tabs = self.tabs ?? TabsModel()
            self.tabs = tabs
            setRoot(RootCarouselViewController(environment: environment, tabs: tabs, client: client), animated: animated)
        } else {
            if window.rootViewController is LoginViewController { return }
            tabs = nil
            setRoot(LoginViewController(environment: environment), animated: animated)
        }
    }

    private func setRoot(_ viewController: UIViewController, animated: Bool) {
        guard let window else { return }
        // Tear down anything the outgoing root presented (e.g. the login Safari
        // sheet) — replacing `rootViewController` alone leaves presented modals
        // orphaned on the window.
        window.rootViewController?.dismiss(animated: false)
        guard animated, window.rootViewController != nil else {
            window.rootViewController = viewController
            return
        }
        UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
            window.rootViewController = viewController
        }
    }

    // MARK: - Foreground / warming control

    func sceneDidBecomeActive(_ scene: UIScene) {
        environment.setActive(true)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        environment.setActive(false)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Capture any in-tab navigation that happened since the last structural save.
        tabs?.save()
    }
}
