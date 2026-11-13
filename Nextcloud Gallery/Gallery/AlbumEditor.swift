//
//  AlbumEditor.swift
//  Nextcloud Gallery
//
//  Album editing shared by every surface that offers it (Home's strip, the Albums
//  grid, an open album, the Add to Album sheet): the rename/delete prompts, and the
//  ``AlbumChange`` broadcast that keeps every other album surface in step — lists
//  reload, open album levels follow a rename and close on delete.
//

import UIKit

/// A successful edit to the account's albums, broadcast on ``AlbumEditor/didChange``.
nonisolated enum AlbumChange: Sendable {
    /// An album was created or had photos added/removed.
    case contentsChanged(album: String)
    case renamed(from: String, to: String)
    case deleted(album: String)
}

@MainActor
enum AlbumEditor {
    nonisolated static let didChange = Notification.Name("app.lyons.Nextcloud-Gallery.AlbumDidChange")
    private nonisolated static let changeKey = "change"

    static func post(_ change: AlbumChange) {
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: [changeKey: change])
    }

    /// Observes album changes on the main queue. Keep the token and remove it in deinit.
    static func observe(_ handler: @escaping @MainActor (AlbumChange) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: didChange, object: nil, queue: .main) { note in
            guard let change = note.userInfo?[changeKey] as? AlbumChange else { return }
            MainActor.assumeIsolated { handler(change) }
        }
    }

    // MARK: - Menus

    /// Rename + Delete actions for an album, for a context menu or a bar-button menu.
    static func menuElements(forAlbum name: String, client: NextcloudClient, presenter: UIViewController) -> [UIMenuElement] {
        let rename = UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak presenter] _ in
            guard let presenter else { return }
            promptRename(album: name, client: client, from: presenter)
        }
        let delete = UIAction(title: "Delete Album", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak presenter] _ in
            guard let presenter else { return }
            confirmDelete(album: name, client: client, from: presenter)
        }
        return [rename, UIMenu(options: .displayInline, children: [delete])]
    }

    // MARK: - Prompts

    /// Asks for a new name, then renames the album and broadcasts the change.
    static func promptRename(album name: String, client: NextcloudClient, from presenter: UIViewController) {
        let alert = UIAlertController(title: "Rename Album", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.text = name
            $0.placeholder = "Album Name"
            $0.autocapitalizationType = .words
            $0.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak presenter, weak alert] _ in
            guard let newName = validatedName(alert?.textFields?.first?.text), newName != name else { return }
            Task {
                do {
                    try await client.renameAlbum(named: name, to: newName)
                    post(.renamed(from: name, to: newName))
                } catch {
                    if let presenter { presentError(error, title: "Couldn't Rename Album", from: presenter) }
                }
            }
        })
        presenter.present(alert, animated: true)
    }

    /// Confirms, then deletes the album and broadcasts the change.
    static func confirmDelete(album name: String, client: NextcloudClient, from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Delete \u{201C}\(name)\u{201D}?",
            message: "The photos in this album won't be deleted.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak presenter] _ in
            Task {
                do {
                    try await client.deleteAlbum(named: name)
                    post(.deleted(album: name))
                } catch {
                    if let presenter { presentError(error, title: "Couldn't Delete Album", from: presenter) }
                }
            }
        })
        presenter.present(alert, animated: true)
    }

    /// Trims a typed album name; nil if it's empty or contains a `/` (the name is a
    /// WebDAV path component on the server).
    static func validatedName(_ text: String?) -> String? {
        guard let name = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, !name.contains("/") else { return nil }
        return name
    }

    static func presentError(_ error: Error, title: String, from presenter: UIViewController) {
        let message = (error as? GalleryError)?.userMessage ?? error.localizedDescription
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        presenter.present(alert, animated: true)
    }
}
