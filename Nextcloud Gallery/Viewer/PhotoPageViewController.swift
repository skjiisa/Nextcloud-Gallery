//
//  PhotoPageViewController.swift
//  Nextcloud Gallery
//
//  One page of the photo viewer: a progressively-loaded, zoomable image. Loads via
//  ``PhotoLoader`` (cached thumb → preview → full file) and crossfades each stage
//  in as it sharpens.
//

import UIKit

final class PhotoPageViewController: UIViewController {
    let photo: PhotoItem
    private let environment: AppEnvironment
    private let loader = PhotoLoader()
    private let scrollView = ZoomableImageScrollView()
    private let spinner = UIActivityIndicatorView(style: .large)

    /// Forwarded zoom state, so the pager can disable horizontal paging while zoomed.
    var onZoomChanged: ((Bool) -> Void)?

    private var loaderObservation: ObservationToken?
    private var loadTask: Task<Void, Never>?

    init(photo: PhotoItem, environment: AppEnvironment) {
        self.photo = photo
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { loadTask?.cancel() }

    /// The best image currently shown (thumb → preview → full). Seeds the viewer's
    /// close transition so it shrinks the crispest image available.
    var displayedImage: UIImage? { scrollView.image }

    /// On-screen rect of the displayed photo in `view`'s coordinates (honors
    /// zoom/pan), or nil before the first image loads.
    func displayedImageRect(in view: UIView) -> CGRect? { scrollView.displayedImageRect(in: view) }

    /// Whether the photo is zoomed past its fitted size (gates swipe-to-dismiss).
    var isZoomed: Bool { scrollView.isZoomedIn }

    /// This page's double-tap-to-zoom recognizer, so the viewer's chrome-toggle tap
    /// can require it to fail.
    var zoomDoubleTap: UITapGestureRecognizer { scrollView.doubleTap }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear so the viewer's theme-matched backdrop shows through (and so the
        // grid shows through during the grow-open / swipe-dismiss transitions).
        view.backgroundColor = .clear

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.onZoomChanged = { [weak self] zoomed in self?.onZoomChanged?(zoomed) }
        view.addSubview(scrollView)

        spinner.color = .secondaryLabel
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        loaderObservation = observeChanges { [weak self] in
            guard let self else { return }
            let image = self.loader.image
            self.apply(image)
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loader.load(photo: self.photo, environment: self.environment)
        }
    }

    private func apply(_ image: UIImage?) {
        guard let image else { return }
        let isFirst = scrollView.image == nil
        spinner.stopAnimating()
        if isFirst {
            UIView.transition(with: scrollView, duration: 0.15, options: .transitionCrossDissolve) {
                self.scrollView.image = image
            }
        } else {
            scrollView.image = image
        }
    }
}
