//
//  AlbumPickerViewController.swift
//  Nextcloud Gallery
//
//  A sheet for adding one photo to a Nextcloud Photos album: pick an existing album
//  or create a new one. Album membership is a COPY into the album collection — a
//  virtual reference, so the original file is untouched (see ``NextcloudClient``
//  albums extension).
//

import UIKit

final class AlbumPickerViewController: UITableViewController {
    private let photo: PhotoItem
    private let client: NextcloudClient

    private enum LoadState { case loading, loaded, failed(String) }
    private enum Section: Int, CaseIterable { case create, albums }

    private var albums: [Album] = []
    private var state: LoadState = .loading
    /// Set while an add/create is in flight, to ignore further taps until it resolves.
    private var busy = false

    init(photo: PhotoItem, client: NextcloudClient) {
        self.photo = photo
        self.client = client
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Add to Album"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        Task { await load() }
    }

    private func load() async {
        state = .loading
        tableView.reloadData()
        do {
            albums = try await client.listAlbums()
            state = .loaded
        } catch {
            state = .failed((error as? GalleryError)?.userMessage ?? error.localizedDescription)
        }
        tableView.reloadData()
    }

    @objc private func cancel() { dismiss(animated: true) }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .create: return 1
        case .albums:
            if case .loaded = state { return max(albums.count, 1) }
            return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section) == .albums ? "Albums" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        switch Section(rawValue: indexPath.section)! {
        case .create:
            content.text = "New Album…"
            content.image = UIImage(systemName: "plus.rectangle.on.rectangle")
        case .albums:
            switch state {
            case .loading:
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
                cell.selectionStyle = .none
            case .failed(let message):
                content.text = message
                content.textProperties.color = .secondaryLabel
                cell.selectionStyle = .none
            case .loaded where albums.isEmpty:
                content.text = "No albums yet"
                content.textProperties.color = .secondaryLabel
                cell.selectionStyle = .none
            case .loaded:
                let album = albums[indexPath.row]
                content.text = album.name
                content.secondaryText = album.photoCount == 1 ? "1 photo" : "\(album.photoCount) photos"
                content.image = UIImage(systemName: "rectangle.stack")
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy else { return }
        switch Section(rawValue: indexPath.section)! {
        case .create:
            promptNewAlbum()
        case .albums:
            guard case .loaded = state, !albums.isEmpty else { return }
            add(to: albums[indexPath.row])
        }
    }

    // MARK: - Actions

    private func add(to album: Album) {
        busy = true
        Task {
            do {
                try await client.addToAlbum(album, photoServerPath: photo.serverPath, fileName: photo.fileName)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss(animated: true)
            } catch {
                busy = false
                presentError(error)
            }
        }
    }

    private func promptNewAlbum() {
        let alert = UIAlertController(title: "New Album", message: "This photo will be added to the new album.", preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Album Name"
            $0.autocapitalizationType = .words
            $0.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            self.createAndAdd(name: name)
        })
        present(alert, animated: true)
    }

    private func createAndAdd(name: String) {
        busy = true
        Task {
            do {
                try await client.createAlbum(named: name)
                // `addToAlbum` builds the destination from the album name; davPath isn't needed.
                let album = Album(name: name, davPath: "", photoCount: 0, coverFileId: nil)
                try await client.addToAlbum(album, photoServerPath: photo.serverPath, fileName: photo.fileName)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss(animated: true)
            } catch {
                busy = false
                presentError(error)
            }
        }
    }

    private func presentError(_ error: Error) {
        let message = (error as? GalleryError)?.userMessage ?? error.localizedDescription
        let alert = UIAlertController(title: "Couldn't Add to Album", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}
