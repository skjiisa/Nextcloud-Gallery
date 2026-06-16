//
//  WindowSnapshot.swift
//  Nextcloud Gallery
//
//  Grabs a bitmap of what's on screen, used to fill the tab switcher's cards with
//  a live thumbnail of each tab as it looked when you last left it.
//

import UIKit

enum WindowSnapshot {
    /// Renders the current foreground window to an image. Fast (`afterScreenUpdates:
    /// false` captures the already-drawn frame), so it's safe to call synchronously
    /// just before switching tabs or opening the switcher.
    @MainActor
    static func capture() -> UIImage? {
        guard let window = keyWindow else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    @MainActor
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
