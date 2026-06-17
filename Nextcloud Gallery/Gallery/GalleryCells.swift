//
//  GalleryCells.swift
//  Nextcloud Gallery
//
//  Collection-view cells for the gallery grids: a single-photo tile and a folder
//  tile with a 2x2 cover composite. Both load thumbnails via ``ThumbnailImageView``
//  (cancel-on-reuse) and never touch SwiftData — they render plain
//  ``GridItemSnapshot`` values handed down by the grid.
//

import UIKit

// MARK: - Photo cell

/// A single square photo tile backed by a cached grid thumbnail.
///
/// Fill mode: the photo fills the square slot (cropped). Fit mode: the thumbnail
/// view shrinks to the photo's own aspect ratio within the square so the whole
/// photo shows — and because the rounded corners live on *that* view (the photo's
/// display rect, not the square slot), they clip the photo itself at any aspect
/// ratio. Toggling fit/fill animates the resize.
final class PhotoGridCell: UICollectionViewCell {
    static let reuseID = "PhotoGridCell"

    private let thumbnail = ThumbnailImageView()
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var photoAspect: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.imageContentMode = .scaleAspectFill
        contentView.addSubview(thumbnail)
        // Photo rect, centered; its size relative to the square slot is what fit/fill
        // changes (see `applyAppearance`). Starts filling the slot.
        widthConstraint = thumbnail.widthAnchor.constraint(equalTo: contentView.widthAnchor)
        heightConstraint = thumbnail.heightAnchor.constraint(equalTo: contentView.heightAnchor)
        NSLayoutConstraint.activate([
            thumbnail.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            thumbnail.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            widthConstraint, heightConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        with item: GridItemSnapshot,
        fill: Bool,
        cornerRadius: CGFloat,
        store: ThumbnailStore,
        client: NextcloudClient
    ) {
        photoAspect = item.aspectRatio
        applyAppearance(fill: fill, cornerRadius: cornerRadius, animated: false)
        thumbnail.load(
            ocId: item.ocId, fileId: item.fileId, etag: item.etag,
            pixels: NextcloudConfig.gridThumbnailPixels, store: store, client: client
        )
    }

    /// Sizes the photo rect — square for fill, the photo's aspect fitted within the
    /// square for fit — and sets its corner radius. Animated when toggled live.
    func applyAppearance(fill: Bool, cornerRadius: CGFloat, animated: Bool) {
        let wMult: CGFloat, hMult: CGFloat
        if fill {
            (wMult, hMult) = (1, 1)
        } else if photoAspect >= 1 {
            (wMult, hMult) = (1, 1 / photoAspect) // landscape: full width, shorter height
        } else {
            (wMult, hMult) = (photoAspect, 1)     // portrait: full height, narrower width
        }

        // A constraint's multiplier is immutable, so swap the width/height constraints.
        NSLayoutConstraint.deactivate([widthConstraint, heightConstraint])
        widthConstraint = thumbnail.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: wMult)
        heightConstraint = thumbnail.heightAnchor.constraint(equalTo: contentView.heightAnchor, multiplier: hMult)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])

        // Fit mode (whole photo, Photos-style) rounds a touch more than fill.
        let radius = fill ? cornerRadius : cornerRadius * 1.5
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: radius))

        if animated {
            let cornerAnim = CABasicAnimation(keyPath: "cornerRadius")
            cornerAnim.fromValue = thumbnail.layer.cornerRadius
            cornerAnim.toValue = radius
            cornerAnim.duration = 0.35
            thumbnail.layer.add(cornerAnim, forKey: "cornerRadius")
            thumbnail.layer.cornerRadius = radius
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                self.contentView.layoutIfNeeded()
            }
        } else {
            thumbnail.layer.cornerRadius = radius
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.prepareForReuse()
    }
}

// MARK: - Folder cell

/// A square folder tile whose artwork is a 2x2 composite of photos from within the
/// folder and its subtree, with the folder name along the bottom.
final class FolderGridCell: UICollectionViewCell {
    static let reuseID = "FolderGridCell"

    private let placeholder = UIImageView(image: UIImage(systemName: "folder.fill"))
    private let singleTile = ThumbnailImageView()
    private let gridTiles = (0..<4).map { _ in ThumbnailImageView() }
    private let gridContainer = UIView()
    private let nameLabel = UILabel()
    private let nameBackground = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = LayoutMetrics.tileCornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.backgroundColor = .quaternarySystemFill

        // Placeholder (no cover yet).
        placeholder.tintColor = .secondaryLabel
        placeholder.contentMode = .scaleAspectFit
        placeholder.preferredSymbolConfiguration = .init(pointSize: 34)
        addFilling(placeholder)

        // Single-tile cover.
        addFilling(singleTile)

        // 2x2 cover.
        let rows = UIStackView(arrangedSubviews: [
            rowStack(gridTiles[0], gridTiles[1]),
            rowStack(gridTiles[2], gridTiles[3]),
        ])
        rows.axis = .vertical
        rows.spacing = 1
        rows.distribution = .fillEqually
        rows.translatesAutoresizingMaskIntoConstraints = false
        gridContainer.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: gridContainer.topAnchor),
            rows.bottomAnchor.constraint(equalTo: gridContainer.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: gridContainer.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: gridContainer.trailingAnchor),
        ])
        addFilling(gridContainer)

        // Name label along the bottom over a scrim.
        nameBackground.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        nameBackground.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameBackground)
        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameBackground.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            nameBackground.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameBackground.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            nameBackground.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: nameBackground.leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: nameBackground.trailingAnchor, constant: -6),
            nameLabel.topAnchor.constraint(equalTo: nameBackground.topAnchor, constant: 4),
            nameLabel.bottomAnchor.constraint(equalTo: nameBackground.bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with item: GridItemSnapshot, store: ThumbnailStore, client: NextcloudClient) {
        nameLabel.text = item.fileName
        GalleryTile.applyHoverStyle(to: self, cornerRadius: LayoutMetrics.tileCornerRadius)

        let tiles = item.coverTiles
        let pixels = NextcloudConfig.coverTilePixels

        switch tiles.count {
        case 0:
            placeholder.isHidden = false
            singleTile.isHidden = true
            gridContainer.isHidden = true
        case 1:
            placeholder.isHidden = true
            singleTile.isHidden = false
            gridContainer.isHidden = true
            singleTile.load(ocId: tiles[0].ocId, fileId: tiles[0].fileId, etag: tiles[0].etag, pixels: pixels, store: store, client: client)
        default:
            placeholder.isHidden = true
            singleTile.isHidden = true
            gridContainer.isHidden = false
            for (index, view) in gridTiles.enumerated() {
                if index < tiles.count {
                    view.load(ocId: tiles[index].ocId, fileId: tiles[index].fileId, etag: tiles[index].etag, pixels: pixels, store: store, client: client)
                } else {
                    view.showBlank()
                }
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        singleTile.prepareForReuse()
        gridTiles.forEach { $0.prepareForReuse() }
    }

    // MARK: helpers

    private func rowStack(_ a: ThumbnailImageView, _ b: ThumbnailImageView) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [a, b])
        stack.axis = .horizontal
        stack.spacing = 1
        stack.distribution = .fillEqually
        return stack
    }

    private func addFilling(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }
}

// MARK: - Shared tile interaction

enum GalleryTile {
    /// Applies the system hover highlight clipped to the tile's rounded rect — the
    /// UIKit equivalent of the old `galleryTileInteraction()`. Drives iPad pointer
    /// hover and visionOS eye-tracking highlights; inert on iPhone.
    static func applyHoverStyle(to cell: UICollectionViewCell, cornerRadius: CGFloat) {
        cell.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: cornerRadius))
    }
}
