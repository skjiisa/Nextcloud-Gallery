//
//  HomeCells.swift
//  Nextcloud Gallery
//
//  Cells and supplementary views for ``HomeViewController``: an album tile (a cover
//  thumbnail with the album name + photo count over a scrim, mirroring
//  ``FolderGridCell``) and a section header with an optional trailing action.
//

import UIKit

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
        nameLabel.text = album.name
        countLabel.text = album.photoCount == 1 ? "1 photo" : "\(album.photoCount) photos"
        GalleryTile.applyHoverStyle(to: self, cornerRadius: LayoutMetrics.tileCornerRadius)

        if let cover = album.coverFileId {
            placeholder.isHidden = true
            // The album endpoint gives only the cover's file id; preview-by-id ignores
            // the etag, so the file id doubles as a stable cache key.
            thumbnail.isHidden = false
            thumbnail.load(ocId: cover, fileId: cover, etag: cover, pixels: NextcloudConfig.coverTilePixels, store: store, client: client)
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
