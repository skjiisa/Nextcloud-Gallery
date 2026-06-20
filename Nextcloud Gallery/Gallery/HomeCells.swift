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

// MARK: - File-browser button

/// A tappable card with an icon over a short label, used for Home's file-browser row
/// (open the media folder as a gallery / folder, browse the root, set the media folder).
final class HomeButtonCell: UICollectionViewCell {
    static let reuseID = "HomeButtonCell"

    private let iconView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .tintColor
        iconView.preferredSymbolConfiguration = .init(pointSize: 26, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .vertical)

        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(icon: String, title: String) {
        iconView.image = UIImage(systemName: icon)
        label.text = title
        GalleryTile.applyHoverStyle(to: self, cornerRadius: 14)
    }
}

// MARK: - Tag chip

/// A rounded pill carrying a tag's colour dot and name, for Home's Tags strip.
final class TagChipCell: UICollectionViewCell {
    static let reuseID = "TagChipCell"

    private let dot = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerCurve = .continuous

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = 5
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dot)
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.layer.cornerRadius = contentView.bounds.height / 2   // full pill
    }

    func configure(tag: NKTag) {
        label.text = tag.name
        dot.backgroundColor = tag.color.flatMap(UIColor.init(hex:)) ?? .systemGray
        GalleryTile.applyHoverStyle(to: self, cornerRadius: 18)
    }
}
