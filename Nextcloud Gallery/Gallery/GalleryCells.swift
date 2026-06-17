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
final class PhotoGridCell: UICollectionViewCell {
    static let reuseID = "PhotoGridCell"

    private let thumbnail = ThumbnailImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(thumbnail)
        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbnail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        with item: GridItemSnapshot,
        contentMode: UIView.ContentMode,
        cornerRadius: CGFloat,
        store: ThumbnailStore,
        client: NextcloudClient
    ) {
        thumbnail.imageContentMode = contentMode
        // Fit mode (whole photo, Photos-style) rounds a touch more than fill.
        thumbnail.layer.cornerRadius = contentMode == .scaleAspectFit ? cornerRadius * 1.5 : cornerRadius
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.backgroundColor = contentMode == .scaleAspectFit ? .clear : .quaternarySystemFill
        GalleryTile.applyHoverStyle(to: self, cornerRadius: thumbnail.layer.cornerRadius)

        thumbnail.load(
            ocId: item.ocId, fileId: item.fileId, etag: item.etag,
            pixels: NextcloudConfig.gridThumbnailPixels, store: store, client: client
        )
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
