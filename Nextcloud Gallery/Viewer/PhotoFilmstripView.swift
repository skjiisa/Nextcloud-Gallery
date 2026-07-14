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
//  folder tile — the file browser's 2x2 cover look — bookends the strip on that
//  side; tapping it jumps the viewer into that folder.
//

import UIKit

@MainActor
final class PhotoFilmstripView: UIView {
    /// A neighbor folder shown as a square cover tile past the strip's end — the
    /// same 2x2 composite artwork the file browser gives folders.
    struct FolderPreview: Equatable {
        let title: String
        let coverTiles: [CoverTile]
    }

    /// Fired when the user scrubs/taps to a new photo (never for programmatic syncs).
    var onIndexChanged: ((Int) -> Void)?

    /// Fired when an end-of-strip folder tile is tapped (`true` = the next folder).
    var onFolderTapped: ((_ forward: Bool) -> Void)?

    /// Preferred height for the whole strip (thumbnails + vertical padding).
    static let preferredHeight: CGFloat = 64
    private let itemHeight: CGFloat = 48
    private let spacing: CGFloat = 4

    private let photos: [PhotoItem]
    private let store: ThumbnailStore
    private let client: NextcloudClient?

    /// Index into ``photos`` (folder tiles are not part of this).
    private(set) var currentIndex: Int
    private var pendingCenterIndex: Int?
    private var lastCenteringWidth: CGFloat = -1

    /// The sibling folders bookending this one, shown as square cover tiles before
    /// the first and after the last photo. Arrive asynchronously once resolved.
    private var prevFolder: FolderPreview?
    private var nextFolder: FolderPreview?
    /// How many strip items sit before the first photo (the leading folder tile).
    private var leadingOffset: Int { prevFolder == nil ? 0 : 1 }

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
        cv.dataSource = self
        cv.delegate = self
        cv.register(FilmstripCell.self, forCellWithReuseIdentifier: FilmstripCell.reuseID)
        cv.register(FilmstripFolderCell.self, forCellWithReuseIdentifier: FilmstripFolderCell.reuseID)
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
        // Inset by half the width so the first and last items can sit dead center.
        let half = bounds.width / 2
        if collectionView.contentInset.left != half {
            collectionView.contentInset = UIEdgeInsets(top: 0, left: half, bottom: 0, right: half)
        }
        // Re-center on first layout / width change (e.g. rotation).
        if bounds.width > 0, bounds.width != lastCenteringWidth {
            lastCenteringWidth = bounds.width
            collectionView.collectionViewLayout.invalidateLayout()
            centerItem(pendingCenterIndex ?? currentIndex, animated: false)
            pendingCenterIndex = nil
        }
    }

    /// Shows (or updates) the neighbor-folder tiles at the strip's ends. Adding the
    /// leading tile shifts every photo item, so the current photo is re-centered —
    /// skipped while the user is mid-scrub so it never fights their finger.
    func setNeighborFolders(previous: FolderPreview?, next: FolderPreview?) {
        guard previous != prevFolder || next != nextFolder else { return }
        prevFolder = previous
        nextFolder = next
        collectionView.reloadData()
        guard bounds.width > 0,
              !collectionView.isTracking, !collectionView.isDecelerating else { return }
        collectionView.layoutIfNeeded()
        centerItem(currentIndex, animated: false)
    }

    /// Centers + highlights `index` without firing `onIndexChanged`. Called by the
    /// viewer when the pager turns so the strip follows the big photo.
    func select(index: Int, animated: Bool) {
        guard photos.indices.contains(index) else { return }
        currentIndex = index
        guard bounds.width > 0 else { pendingCenterIndex = index; return }
        centerItem(index, animated: animated)
        refreshHighlight()
    }

    private func centerItem(_ index: Int, animated: Bool) {
        guard photos.indices.contains(index) else { return }
        collectionView.scrollToItem(at: IndexPath(item: index + leadingOffset, section: 0), at: .centeredHorizontally, animated: animated)
    }

    private func refreshHighlight() {
        for case let cell as FilmstripCell in collectionView.visibleCells {
            guard let ip = collectionView.indexPath(for: cell) else { continue }
            cell.setCurrent(photoIndex(forItem: ip.item) == currentIndex)
        }
    }

    /// The photo index a strip item shows, or nil for a folder tile.
    private func photoIndex(forItem item: Int) -> Int? {
        let index = item - leadingOffset
        return photos.indices.contains(index) && !isFolderItem(item) ? index : nil
    }

    private func isFolderItem(_ item: Int) -> Bool {
        (prevFolder != nil && item == 0)
            || (nextFolder != nil && item == photos.count + leadingOffset)
    }

    /// The photo whose item center is nearest the strip's horizontal center (a
    /// centered folder tile maps to no photo and is ignored).
    private func centeredPhotoIndex() -> Int? {
        let centerX = collectionView.contentOffset.x + collectionView.bounds.width / 2
        let point = CGPoint(x: centerX, y: collectionView.contentSize.height / 2)
        guard let item = collectionView.indexPathForItem(at: point)?.item else { return nil }
        return photoIndex(forItem: item)
    }
}

// MARK: - Data source + delegate

extension PhotoFilmstripView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        photos.count + leadingOffset + (nextFolder == nil ? 0 : 1)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if isFolderItem(indexPath.item) {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilmstripFolderCell.reuseID, for: indexPath) as! FilmstripFolderCell
            if let preview = indexPath.item == 0 && prevFolder != nil ? prevFolder : nextFolder {
                cell.configure(with: preview, store: store, client: client)
            }
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilmstripCell.reuseID, for: indexPath) as! FilmstripCell
        let index = photoIndex(forItem: indexPath.item) ?? 0
        cell.configure(with: photos[index], store: store, client: client)
        cell.setCurrent(index == currentIndex)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        // Folder tiles are square, like the file browser's.
        guard let index = photoIndex(forItem: indexPath.item) else {
            return CGSize(width: itemHeight, height: itemHeight)
        }
        let aspect = photos[index].aspectRatio
        let width = (itemHeight * aspect).clamped(to: itemHeight * 0.6 ... itemHeight * 1.8)
        return CGSize(width: width, height: itemHeight)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if isFolderItem(indexPath.item) {
            onFolderTapped?(indexPath.item != 0 || prevFolder == nil)
            return
        }
        guard let index = photoIndex(forItem: indexPath.item), index != currentIndex else { return }
        select(index: index, animated: true)
        onIndexChanged?(index)
    }

    // Only react while the user is physically scrubbing — not to our own
    // `scrollToItem` centering (which leaves these tracking flags false).
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking else { return }
        guard let index = centeredPhotoIndex(), index != currentIndex else { return }
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

/// A neighbor folder's square tile: the file browser's cover artwork
/// (``FolderCoverView`` — placeholder icon, single cover, or 2x2 composite).
private final class FilmstripFolderCell: UICollectionViewCell {
    static let reuseID = "FilmstripFolderCell"

    private let cover = FolderCoverView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.layer.cornerRadius = 4
        cover.layer.cornerCurve = .continuous
        cover.clipsToBounds = true
        contentView.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: contentView.topAnchor),
            cover.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with preview: PhotoFilmstripView.FolderPreview, store: ThumbnailStore, client: NextcloudClient?) {
        guard let client else { return }
        cover.configure(
            coverTiles: preview.coverTiles, placeholderSymbol: "folder.fill",
            pixels: NextcloudConfig.coverTilePixels, store: store, client: client
        )
        accessibilityLabel = preview.title
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cover.prepareForReuse()
    }
}

// MARK: - Util

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
