//
//  FolderEdgeNavigation.swift
//  Nextcloud Gallery
//
//  Cross-folder navigation from the ends of the photo viewer's carousel: pulling
//  past the last photo (or before the first) reveals a hint pill naming the next
//  (previous) sibling folder; releasing past the threshold jumps the viewer there.
//  The pull has rubber-band resistance up to the threshold, then tracks 1:1 (see
//  ``PhotoViewerController/handleFolderPan(_:)``).
//

import UIKit

/// A sibling folder the viewer can continue into from either end of its carousel,
/// resolved by the host (see ``BrowseNavController``): the folder's photos in the
/// same presentation as the current one, plus the route the tab should adopt when
/// the jump commits. Only folders with at least one photo are offered.
struct ViewerFolderNeighbor {
    /// The folder's display name, shown in the pull hint.
    let title: String
    /// The folder's photos, non-empty, in the order the viewer should page them.
    let photos: [PhotoItem]
    /// The route that replaces the tab's top level when the navigation commits.
    let route: BrowseRoute
    /// The folder's 2x2 cover tiles (as the file browser shows it), for the
    /// filmstrip's end-of-strip folder preview. Empty → placeholder folder icon.
    let coverTiles: [CoverTile]
}

/// The capsule that slides in from the screen edge during a folder pull, naming
/// the destination folder. `setProgress` rides the pull (0 = hidden off-edge,
/// 1 = fully revealed at the threshold); `setEngaged` lights it up once releasing
/// would commit.
@MainActor
final class FolderEdgeHintView: UIView {
    /// True when the pill enters from the trailing edge (pulling toward the *next*
    /// folder); false for the leading edge (previous folder).
    private let forward: Bool
    private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let icon = UIImageView()
    private let label = UILabel()

    init(title: String, forward: Bool) {
        self.forward = forward
        super.init(frame: .zero)

        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        icon.image = UIImage(systemName: "folder.fill")
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        label.text = title
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7

        let chevron = UIImageView(image: UIImage(systemName: forward ? "chevron.right" : "chevron.left"))
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        chevron.tintColor = .secondaryLabel

        // The chevron points off the edge the pill came from, so it reads as
        // "keep pulling to continue this way".
        let views: [UIView] = forward ? [icon, label, chevron] : [chevron, icon, label]
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: background.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor, constant: -14),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        setEngaged(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.layer.cornerRadius = bounds.height / 2
    }

    /// Slides the pill in from its edge: 0 fully off-screen, 1 fully revealed with
    /// a small margin. Driven every move by the pull distance (never animated —
    /// it must track the finger).
    func setProgress(_ progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        let travel = bounds.width + 16
        transform = CGAffineTransform(translationX: (forward ? -1 : 1) * travel * clamped, y: 0)
    }

    /// Lights the pill up (tint + slight grow) once the pull is past the commit
    /// threshold, and back down if the finger retreats.
    func setEngaged(_ engaged: Bool) {
        UIView.animate(withDuration: 0.15) {
            self.icon.tintColor = engaged ? .white : .secondaryLabel
            self.label.textColor = engaged ? .white : .label
            self.background.contentView.backgroundColor = engaged ? self.tintColor : .clear
        }
    }
}
