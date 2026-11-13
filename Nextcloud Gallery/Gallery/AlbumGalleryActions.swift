//
//  AlbumGalleryActions.swift
//  Nextcloud Gallery
//
//  The album-specific half of an open album: fetches its contents (remembering each
//  photo's entry name in the album, which removal needs), offers Rename / Delete in
//  the bar menu and "Remove from Album" on long-press, and follows album changes made
//  anywhere in the app (rename → retitle, contents → reload). Closing the level when
//  the album is deleted is the navigation stack's job (``BrowseNavController``).
//

import UIKit

final class AlbumGalleryActions: RemoteGalleryActions {
    weak var gallery: RemoteGalleryViewController?

    private(set) var albumName: String
    private let client: NextcloudClient
    /// File id → the photo's entry name in the album collection, from the last fetch.
    private var entryNames: [String: String] = [:]
    private var changeObserver: NSObjectProtocol?

    init(albumName: String, client: NextcloudClient) {
        self.albumName = albumName
        self.client = client
        changeObserver = AlbumEditor.observe { [weak self] change in self?.handle(change) }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    /// The gallery's fetch: the album's photos, recording their entry names.
    func fetch() async throws -> [GridItemSnapshot] {
        let contents = try await client.albumContents(named: albumName)
        entryNames = contents.entryNames
        return contents.photos
    }

    // MARK: - RemoteGalleryActions

    func barMenu() -> UIMenu? {
        // Deferred so the actions always target the album's *current* name.
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, let gallery = self.gallery else { return completion([]) }
            completion(AlbumEditor.menuElements(forAlbum: self.albumName, client: self.client, presenter: gallery))
        }])
    }

    func contextMenuActions(for item: GridItemSnapshot) -> [UIMenuElement] {
        let remove = UIAction(
            title: "Remove from Album",
            image: UIImage(systemName: "rectangle.stack.badge.minus"),
            attributes: .destructive
        ) { [weak self] _ in self?.remove(item) }
        return [remove]
    }

    // MARK: - Editing

    private func remove(_ item: GridItemSnapshot) {
        let album = albumName
        // The Photos backend names album entries `{fileId}-{fileName}`; prefer the
        // name the server actually listed.
        let entryName = entryNames[item.fileId] ?? "\(item.fileId)-\(item.fileName)"
        Task {
            do {
                try await client.removeFromAlbum(named: album, entryName: entryName)
                entryNames[item.fileId] = nil
                gallery?.removeItem(ocId: item.ocId)
                AlbumEditor.post(.contentsChanged(album: album))
            } catch {
                if let gallery { AlbumEditor.presentError(error, title: "Couldn't Remove Photo", from: gallery) }
            }
        }
    }

    private func handle(_ change: AlbumChange) {
        switch change {
        case .renamed(let from, let to) where from == albumName:
            albumName = to
            gallery?.setGalleryTitle(to)
        case .contentsChanged(let album) where album == albumName:
            // Our own removals already updated the grid; a reload is harmless and
            // also picks up adds made from the viewer.
            gallery?.reload()
        default:
            break
        }
    }
}
