//
//  HomeCells.swift
//  Nextcloud Gallery
//
//  Cells and supplementary views for ``HomeViewController``: an album tile (a cover
//  thumbnail with the album name + photo count over a scrim, mirroring
//  ``FolderGridCell``) and a section header with an optional trailing action, plus a
//  file-browser button card and a tag chip.
//

import UIKit
import NextcloudKit

// MARK: - Album tile

/// A square album tile: the cover photo (loaded by file id alone) under a bottom
/// scrim carrying the album name and photo count.
final class AlbumGridCell: UICollectionViewCell {
    static let reuseID = "AlbumGridCell"

    private let placeholder = UIImageView(image: UIImage(systemName: "rectangle.stack.fill"))
    private let thumbnail = ThumbnailImageView()
    private let scrim = UIView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = LayoutMetrics.tileCornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.backgroundColor = .quaternarySystemFill

        placeholder.tintColor = .secondaryLabel
        placeholder.contentMode = .scaleAspectFit
        placeholder.preferredSymbolConfiguration = .init(pointSize: 30)
        addFilling(placeholder)
        addFilling(thumbnail)

        // Bottom scrim for legibility of the labels over any cover.
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        scrim.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrim)

        nameLabel.font = .preferredFont(forTextStyle: .subheadline)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1
        countLabel.font = .preferredFont(forTextStyle: .caption2)
        countLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        countLabel.numberOfLines = 1

        let labels = UIStackView(arrangedSubviews: [nameLabel, countLabel])
        labels.axis = .vertical
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false
        scrim.addSubview(labels)

        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            labels.leadingAnchor.constraint(equalTo: scrim.leadingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: scrim.trailingAnchor, constant: -8),
            labels.topAnchor.constraint(equalTo: scrim.topAnchor, constant: 6),
            labels.bottomAnchor.constraint(equalTo: scrim.bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with album: Album, store: ThumbnailStore, client: NextcloudClient) {
        let subtitle = album.photoCount == 1 ? "1 photo" : "\(album.photoCount) photos"
        configure(coverFileId: album.coverFileId, name: album.name, subtitle: subtitle,
                  placeholderSymbol: "rectangle.stack.fill", store: store, client: client)
    }

    /// Generic cover-tile configuration, reused for albums and tags. `coverFileId` is a
    /// single representative photo (preview-by-id ignores the etag, so the file id
    /// doubles as a stable cache key); `subtitle` is hidden when nil.
    func configure(coverFileId: String?, name: String, subtitle: String?, placeholderSymbol: String, store: ThumbnailStore, client: NextcloudClient) {
        nameLabel.text = name
        countLabel.text = subtitle
        countLabel.isHidden = subtitle == nil
        placeholder.image = UIImage(systemName: placeholderSymbol)
        GalleryTile.applyHoverStyle(to: self, cornerRadius: LayoutMetrics.tileCornerRadius)

        if let coverFileId {
            placeholder.isHidden = true
            thumbnail.isHidden = false
            thumbnail.load(ocId: coverFileId, fileId: coverFileId, etag: coverFileId, pixels: NextcloudConfig.coverTilePixels, store: store, client: client)
        } else {
            placeholder.isHidden = false
            thumbnail.isHidden = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.prepareForReuse()
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

// MARK: - Section header

/// A section header with a title and an optional trailing action button ("See All").
final class HomeHeaderView: UICollectionReusableView {
    static let kind = "HomeSectionHeader"
    static let reuseID = "HomeHeaderView"

    private let titleLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private var onAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .title3).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        actionButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.addTarget(self, action: #selector(tapAction), for: .touchUpInside)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, actionTitle: String?, onAction: (() -> Void)?) {
        titleLabel.text = title
        self.onAction = onAction
        if let actionTitle, onAction != nil {
            actionButton.setTitle(actionTitle, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }

    @objc private func tapAction() { onAction?() }
}

private extension UIFont {
    /// Returns this font at the given weight, preserving its dynamic-type size.
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

// MARK: - File-browser button

/// A tappable card for Home's file-browser row. The Media folder's Gallery button shows
/// its newest photo full-bleed; the Browse button shows the same folder artwork as
/// everywhere else (``FolderCoverView`` — a 2x2 composite); All Files / Set Media Folder
/// show a centered icon. The name sits over a bottom scrim in the cover modes.
final class HomeButtonCell: UICollectionViewCell {
    static let reuseID = "HomeButtonCell"

    private let singleThumbnail = ThumbnailImageView()
    private let folderCover = FolderCoverView()
    private let scrim = UIView()
    private let coverLabel = UILabel()
    private let iconView = UIImageView()
    private let iconLabel = UILabel()
    private let iconStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Not a *grouped* background: the Home sits on `.systemBackground`, where the
        // grouped colour is white (invisible in light mode).
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        // Cover modes fill the card; the name sits over a bottom scrim.
        singleThumbnail.translatesAutoresizingMaskIntoConstraints = false
        singleThumbnail.imageContentMode = .scaleAspectFill
        contentView.addSubview(singleThumbnail)

        folderCover.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(folderCover)

        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        contentView.addSubview(scrim)

        coverLabel.font = .preferredFont(forTextStyle: .footnote)
        coverLabel.adjustsFontForContentSizeCategory = true
        coverLabel.textColor = .white
        coverLabel.textAlignment = .center
        coverLabel.translatesAutoresizingMaskIntoConstraints = false
        scrim.addSubview(coverLabel)

        // Icon mode: a centered SF icon over a label.
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .tintColor
        iconView.preferredSymbolConfiguration = .init(pointSize: 26, weight: .regular)

        iconLabel.font = .preferredFont(forTextStyle: .footnote)
        iconLabel.adjustsFontForContentSizeCategory = true
        iconLabel.textColor = .label
        iconLabel.textAlignment = .center
        iconLabel.numberOfLines = 2

        iconStack.addArrangedSubview(iconView)
        iconStack.addArrangedSubview(iconLabel)
        iconStack.axis = .vertical
        iconStack.alignment = .center
        iconStack.spacing = 8
        iconStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconStack)

        NSLayoutConstraint.activate([
            singleThumbnail.topAnchor.constraint(equalTo: contentView.topAnchor),
            singleThumbnail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            singleThumbnail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            singleThumbnail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            folderCover.topAnchor.constraint(equalTo: contentView.topAnchor),
            folderCover.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            folderCover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            folderCover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            scrim.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            coverLabel.leadingAnchor.constraint(equalTo: scrim.leadingAnchor, constant: 6),
            coverLabel.trailingAnchor.constraint(equalTo: scrim.trailingAnchor, constant: -6),
            coverLabel.topAnchor.constraint(equalTo: scrim.topAnchor, constant: 5),
            coverLabel.bottomAnchor.constraint(equalTo: scrim.bottomAnchor, constant: -5),

            iconStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 6),
            iconStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `coverTiles` fill the card: a single photo (Gallery), or — when `asFolder` — the
    /// standard 2x2 folder composite (Browse). Empty → the centered SF `icon`.
    func configure(icon: String, title: String, coverTiles: [CoverTile], asFolder: Bool, store: ThumbnailStore, client: NextcloudClient) {
        let hasCover = !coverTiles.isEmpty
        iconStack.isHidden = hasCover
        scrim.isHidden = !hasCover
        coverLabel.isHidden = !hasCover

        if !hasCover {
            folderCover.isHidden = true
            singleThumbnail.isHidden = true
            iconView.image = UIImage(systemName: icon)
            iconLabel.text = title
        } else {
            coverLabel.text = title
            if asFolder {
                folderCover.isHidden = false
                singleThumbnail.isHidden = true
                folderCover.configure(coverTiles: coverTiles, placeholderSymbol: "folder.fill", pixels: NextcloudConfig.coverTilePixels, store: store, client: client)
            } else {
                folderCover.isHidden = true
                singleThumbnail.isHidden = false
                let tile = coverTiles[0]
                singleThumbnail.load(ocId: tile.ocId, fileId: tile.fileId, etag: tile.etag, pixels: NextcloudConfig.coverTilePixels, store: store, client: client)
            }
        }
        GalleryTile.applyHoverStyle(to: self, cornerRadius: 14)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        singleThumbnail.prepareForReuse()
        folderCover.prepareForReuse()
    }
}
