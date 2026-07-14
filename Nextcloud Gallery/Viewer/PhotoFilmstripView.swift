//
//  PhotoFilmstripView.swift
//  Nextcloud Gallery
//
//  The bottom thumbnail scrubber in the full-screen viewer (the native-Photos
//  "filmstrip"). A horizontal strip of cached thumbnails that keeps the current
//  photo centered and highlighted; scrubbing or tapping it changes the large photo.
//
//  Sync is two-way and guarded against feedback: the viewer calls ``select(index:)``
//  when the pager turns (a programmatic, non-firing centering), and the strip calls
//  ``onIndexChanged`` only while the user is physically dragging it.
//
//  When sibling folders neighbor this one (see ``FolderEdgeNavigation``), a square
//  folder tile — the file browser's 2x2 cover look — rides just past the strip's
//  first/last photo, in the scroll view's overscroll region. It scrolls with the
//  content, but the rest offsets are clamped to the end photos, so a bounce always
//  settles on the last photo, never on a folder. Tapping a tile jumps the viewer
//  into that folder.
//

import UIKit

@MainActor
final class PhotoFilmstripView: UIView {
    /// A neighbor folder shown as a square cover tile in the strip's margin — the
    /// same 2x2 composite artwork the file browser gives folders.
    struct FolderPreview: Equatable {
        let title: String
        let coverTiles: [CoverTile]
    }

    /// Fired when the user scrubs/taps to a new photo (never for programmatic syncs).
    var onIndexChanged: ((Int) -> Void)?

    /// Fired when a margin folder tile is tapped (`true` = the next folder).
    var onFolderTapped: ((_ forward: Bool) -> Void)?

    /// Preferred height for the whole strip (thumbnails + vertical padding).
    static let preferredHeight: CGFloat = 64
    private let itemHeight: CGFloat = 48
    private let spacing: CGFloat = 4

    private let photos: [PhotoItem]
    private let store: ThumbnailStore
    private let client: NextcloudClient?

    private(set) var currentIndex: Int
    private var pendingCenterIndex: Int?
    private var lastCenteringWidth: CGFloat = -1

    /// The sibling folders bookending this one, riding beyond the strip's content
    /// as square cover tiles. Arrive asynchronously once resolved.
    private var prevFolder: FolderPreview?
    private var nextFolder: FolderPreview?
    private var prevTile: FilmstripFolderTile?
    private var nextTile: FilmstripFolderTile?

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = spacing
        layout.minimumInteritemSpacing = spacing
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .clear
        cv.showsHorizontalScrollIndicator = false
        cv.decelerationRate = .fast
        cv.clipsToBounds = true
        cv.dataSource = self
        cv.delegate = self
        cv.register(FilmstripCell.self, forCellWithReuseIdentifier: FilmstripCell.reuseID)
        return cv
    }()

    init(photos: [PhotoItem], initialIndex: Int, store: ThumbnailStore, client: NextcloudClient?) {
        self.photos = photos
        self.currentIndex = max(0, min(initialIndex, photos.count - 1))
        self.store = store
        self.client = client
        super.init(frame: .zero)
        pendingCenterIndex = currentIndex
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        // Insets sized so the *rest* offsets clamp to the first/last photo dead
        // center (not the classic half-width, which would let the strip settle
        // past them onto the folder tiles in the overscroll region).
        let insets = UIEdgeInsets(
            top: 0, left: width / 2 - itemWidth(at: 0) / 2,
            bottom: 0, right: width / 2 - itemWidth(at: photos.count - 1) / 2
        )
        if collectionView.contentInset != insets {
            collectionView.contentInset = insets
        }
        layoutFolderTiles()
        // Re-center on first layout / width change (e.g. rotation).
        if width != lastCenteringWidth {
            lastCenteringWidth = width
            collectionView.collectionViewLayout.invalidateLayout()
            centerItem(pendingCenterIndex ?? currentIndex, animated: false)
            pendingCenterIndex = nil
        }
    }

    /// Places the folder tiles just past the strip's content, in the scroll view's
    /// content coordinates — they ride with the photos, but the rest-offset clamp
    /// above means a bounce always returns to the end photo, never onto them.
    private func layoutFolderTiles() {
        let contentWidth = collectionView.collectionViewLayout.collectionViewContentSize.width
        let y = (collectionView.bounds.height - itemHeight) / 2
        prevTile?.frame = CGRect(x: -(itemHeight + spacing), y: y, width: itemHeight, height: itemHeight)
        nextTile?.frame = CGRect(x: contentWidth + spacing, y: y, width: itemHeight, height: itemHeight)
    }

    /// Shows (or updates) the neighbor-folder tiles past the strip's ends.
    func setNeighborFolders(previous: FolderPreview?, next: FolderPreview?) {
        guard previous != prevFolder || next != nextFolder else { return }
        prevFolder = previous
        nextFolder = next
        prevTile = updateTile(prevTile, preview: previous, forward: false)
        nextTile = updateTile(nextTile, preview: next, forward: true)
        setNeedsLayout()
    }

    /// Replaces (or removes) one folder tile, fading the new one in. Tiles are
    /// subviews of the collection view so they pan with its content; their frames
    /// are set in `layoutFolderTiles`.
    private func updateTile(_ tile: FilmstripFolderTile?, preview: FolderPreview?, forward: Bool) -> FilmstripFolderTile? {
        tile?.removeFromSuperview()
        guard let preview, let client else { return nil }
        let new = FilmstripFolderTile(preview: preview, store: store, client: client) { [weak self] in
            self?.onFolderTapped?(forward)
        }
        collectionView.addSubview(new)
        new.alpha = 0
        UIView.animate(withDuration: 0.2) { new.alpha = 1 }
        return new
    }

    /// The width `sizeForItemAt` gives the photo at `index` (square fallback).
    private func itemWidth(at index: Int) -> CGFloat {
        guard photos.indices.contains(index) else { return itemHeight }
        return (itemHeight * photos[index].aspectRatio).clamped(to: itemHeight * 0.6 ... itemHeight * 1.8)
    }

    /// Centers + highlights `index` without firing `onIndexChanged`. Called by the
    /// viewer when the pager turns so the strip follows the big photo.
    func select(index: Int, animated: Bool) {
        guard photos.indices.contains(index) else { return }
        currentIndex = index
        guard collectionView.bounds.width > 0 else { pendingCenterIndex = index; return }
        centerItem(index, animated: animated)
        refreshHighlight()
    }

    private func centerItem(_ index: Int, animated: Bool) {
        guard photos.indices.contains(index) else { return }
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: animated)
    }

    private func refreshHighlight() {
        for case let cell as FilmstripCell in collectionView.visibleCells {
            guard let ip = collectionView.indexPath(for: cell) else { continue }
            cell.setCurrent(ip.item == currentIndex)
        }
    }

    /// The item whose center is nearest the strip's horizontal center.
    private func centeredIndex() -> Int? {
        let centerX = collectionView.contentOffset.x + collectionView.bounds.width / 2
        let point = CGPoint(x: centerX, y: collectionView.contentSize.height / 2)
        return collectionView.indexPathForItem(at: point)?.item
    }
}

// MARK: - Data source + delegate

extension PhotoFilmstripView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        photos.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilmstripCell.reuseID, for: indexPath) as! FilmstripCell
        cell.configure(with: photos[indexPath.item], store: store, client: client)
        cell.setCurrent(indexPath.item == currentIndex)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: itemWidth(at: indexPath.item), height: itemHeight)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item != currentIndex else { return }
        select(index: indexPath.item, animated: true)
        onIndexChanged?(indexPath.item)
    }

    // Only react while the user is physically scrubbing — not to our own
    // `scrollToItem` centering (which leaves these tracking flags false).
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking else { return }
        guard let index = centeredIndex(), index != currentIndex else { return }
        currentIndex = index
        refreshHighlight()
        onIndexChanged?(index)
    }
}

// MARK: - Cells

private final class FilmstripCell: UICollectionViewCell {
    static let reuseID = "FilmstripCell"

    private let thumbnail = ThumbnailImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.imageContentMode = .scaleAspectFill
        thumbnail.layer.cornerRadius = 4
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.layer.borderColor = UIColor.label.cgColor
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

    func configure(with photo: PhotoItem, store: ThumbnailStore, client: NextcloudClient?) {
        guard let client else { return }
        thumbnail.load(
            ocId: photo.ocId, fileId: photo.fileId, etag: photo.etag,
            pixels: NextcloudConfig.gridThumbnailPixels, store: store, client: client
        )
    }

    /// The current item is full-opacity with a hairline outline; the rest are dimmed.
    func setCurrent(_ current: Bool) {
        thumbnail.alpha = current ? 1 : 0.5
        thumbnail.layer.borderWidth = current ? 2 : 0
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.prepareForReuse()
    }
}

/// A neighbor folder's square margin tile: the file browser's cover artwork
/// (``FolderCoverView`` — placeholder icon, single cover, or 2x2 composite),
/// tappable to jump into that folder.
private final class FilmstripFolderTile: UIView {
    private let cover = FolderCoverView()
    private let onTap: () -> Void

    init(preview: PhotoFilmstripView.FolderPreview, store: ThumbnailStore, client: NextcloudClient, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.layer.cornerRadius = 4
        cover.layer.cornerCurve = .continuous
        cover.clipsToBounds = true
        addSubview(cover)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: topAnchor),
            cover.bottomAnchor.constraint(equalTo: bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        cover.configure(
            coverTiles: preview.coverTiles, placeholderSymbol: "folder.fill",
            pixels: NextcloudConfig.coverTilePixels, store: store, client: client
        )
        isAccessibilityElement = true
        accessibilityLabel = preview.title
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped() { onTap() }
}

// MARK: - Util

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
