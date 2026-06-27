//
//  WindowSnapshot.swift
//  Nextcloud Gallery
//
//  Renders a view to a bitmap, used to fill the tab switcher's cards with a thumbnail of
//  each tab as it looked when you last left it (and the lifted bar ghost).
//

import UIKit

enum WindowSnapshot {
    /// Renders an arbitrary view's current content to an image (tab cards, the lifted
    /// bar ghost, etc.). Honours the view's screen scale. Pass `afterScreenUpdates: true`
    /// when the render must reflect changes made in the same run loop (e.g. a just-hidden
    /// subview) — `false` captures the already-drawn frame and ignores them.
    @MainActor
    static func render(_ view: UIView, afterScreenUpdates: Bool = false) -> UIImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.screen.scale ?? 0   // 0 → device scale
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        return renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: afterScreenUpdates) }
    }
}
