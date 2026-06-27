//
//  ThumbnailImageView.swift
//  Nextcloud Gallery
//
//  A UIImageView that loads a cached thumbnail through ``ImageLoader``, showing a
//  placeholder until it arrives and crossfading it in. Cancels its in-flight load
//  on reuse so fast scrolling never applies a stale image to a recycled cell.
//

import UIKit

final class ThumbnailImageView: UIView {
    private let imageView = UIImageView()
    private let placeholderGlyph = UIImageView(image: UIImage(systemName: "photo"))

    private var loadTask: Task<Void, Never>?
    private var currentKeyID: String?

    var imageContentMode: UIView.ContentMode {
        get { imageView.contentMode }
        set { imageView.contentMode = newValue }
    }

    /// A normalized (0...1) crop applied to whatever image is loaded — used to show a
    /// zoom-locked photo's locked framing. Nil shows the whole image. Set before/with
    /// `load`; re-applies if the displayed image changes.
    var crop: CGRect? {
        didSet {
            guard crop != oldValue, let full = fullImage else { return }
            imageView.image = cropped(full)
        }
    }

    /// The uncropped image last applied, so `crop` changes can re-derive from it.
    private var fullImage: UIImage?

    /// The thumbnail currently shown (cropped, if a crop is set), if loaded. Read by the
    /// viewer's open transition to seed its hero image from the tapped tile.
    var image: UIImage? { imageView.image }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .quaternarySystemFill
        clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        placeholderGlyph.tintColor = .tertiaryLabel
        placeholderGlyph.contentMode = .scaleAspectFit
        placeholderGlyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderGlyph)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholderGlyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderGlyph.widthAnchor.constraint(equalToConstant: 28),
            placeholderGlyph.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Loads the thumbnail for the given item at `pixels`. Instant if it's already
    /// decoded in memory; otherwise shows the placeholder and crossfades on arrival.
    func load(ocId: String, fileId: String, etag: String, pixels: Int, store: ThumbnailStore, client: NextcloudClient) {
        let key = ThumbKey(ocId: ocId, etag: etag, pixels: pixels)
        if currentKeyID == key.id, imageView.image != nil { return }
        cancel()
        currentKeyID = key.id

        if let cached = ImageLoader.shared.cachedImage(for: key) {
            apply(cached, animated: false)
            return
        }

        showPlaceholder()
        loadTask = Task { [weak self] in
            let image = await ImageLoader.shared.thumbnail(
                ocId: ocId, fileId: fileId, etag: etag, pixels: pixels, store: store, client: client
            )
            guard let self, self.currentKeyID == key.id, let image, !Task.isCancelled else { return }
            self.apply(image, animated: true)
        }
    }

    /// Resets to an empty quaternary slot (no glyph) — used for blank 2x2 cover cells.
    func showBlank() {
        cancel()
        currentKeyID = nil
        fullImage = nil
        imageView.image = nil
        placeholderGlyph.isHidden = true
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    /// Called from the owning cell's `prepareForReuse`.
    func prepareForReuse() {
        cancel()
        currentKeyID = nil
        fullImage = nil
        crop = nil
        imageView.image = nil
        showPlaceholder()
    }

    private func showPlaceholder() {
        imageView.image = nil
        placeholderGlyph.isHidden = false
    }

    private func apply(_ image: UIImage, animated: Bool) {
        placeholderGlyph.isHidden = true
        fullImage = image
        let shown = cropped(image)
        guard animated else {
            imageView.image = shown
            return
        }
        UIView.transition(with: imageView, duration: 0.15, options: .transitionCrossDissolve) {
            self.imageView.image = shown
        }
    }

    /// Applies the current `crop` to `image`, or returns it whole when there's no crop.
    private func cropped(_ image: UIImage) -> UIImage {
        guard let crop else { return image }
        return image.croppedToNormalized(crop)
    }
}
