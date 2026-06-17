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

import UIKit

@MainActor
final class PhotoFilmstripView: UIView {
    /// Fired when the user scrubs/taps to a new photo (never for programmatic syncs).
    var onIndexChanged: ((Int) -> Void)?

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
        let aspect = photos[indexPath.item].aspectRatio
        let width = (itemHeight * aspect).clamped(to: itemHeight * 0.6 ... itemHeight * 1.8)
        return CGSize(width: width, height: itemHeight)
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

// MARK: - Cell

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

// MARK: - Util

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
