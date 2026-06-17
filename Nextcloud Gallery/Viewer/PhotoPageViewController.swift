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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.onZoomChanged = { [weak self] zoomed in self?.onZoomChanged?(zoomed) }
        view.addSubview(scrollView)

        spinner.color = .white
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
