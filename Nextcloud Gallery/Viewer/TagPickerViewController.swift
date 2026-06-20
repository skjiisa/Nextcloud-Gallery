//
//  TagPickerViewController.swift
//  Nextcloud Gallery
//
//  A sheet for editing a photo's Nextcloud system tags (the tags you manage in the
//  web UI's file sidebar). Lists every tag with a checkmark on the assigned ones;
//  tapping toggles assignment live, and "New Tag…" creates one and applies it.
//

import UIKit
import NextcloudKit

final class TagPickerViewController: UITableViewController {
    private let photo: PhotoItem
    private let client: NextcloudClient

    private enum LoadState { case loading, loaded, failed(String) }
    private enum Section: Int, CaseIterable { case create, tags }

    private var tags: [NKTag] = []
    private var assigned: Set<String> = []
    /// Tag ids with an in-flight assign/unassign, shown with a spinner.
    private var pending: Set<String> = []
    private var state: LoadState = .loading

    init(photo: PhotoItem, client: NextcloudClient) {
        self.photo = photo
        self.client = client
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Tags"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        Task { await load() }
    }

    private func load() async {
        state = .loading
        tableView.reloadData()
        do {
            async let allTags = client.availableTags()
            async let metadata = client.fileMetadata(serverPath: photo.serverPath)
            let (loaded, meta) = try await (allTags, metadata)
            tags = loaded
            assigned = Set(meta.tags.map(\.id))
            state = .loaded
        } catch {
            state = .failed((error as? GalleryError)?.userMessage ?? error.localizedDescription)
        }
        tableView.reloadData()
    }

    @objc private func done() { dismiss(animated: true) }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .create: return 1
        case .tags:
            if case .loaded = state { return max(tags.count, 1) }
            return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section) == .tags ? "Tags" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        cell.accessoryView = nil
        cell.accessoryType = .none

        switch Section(rawValue: indexPath.section)! {
        case .create:
            content.text = "New Tag…"
            content.image = UIImage(systemName: "plus")
        case .tags:
            switch state {
            case .loading:
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
                cell.selectionStyle = .none
            case .failed(let message):
                content.text = message
                content.textProperties.color = .secondaryLabel
                cell.selectionStyle = .none
            case .loaded where tags.isEmpty:
                content.text = "No tags yet"
                content.textProperties.color = .secondaryLabel
                cell.selectionStyle = .none
            case .loaded:
                let tag = tags[indexPath.row]
                content.text = tag.name
                content.image = UIImage(systemName: "tag.fill")
                content.imageProperties.tintColor = tag.color.flatMap(UIColor.init(hex:)) ?? .tertiaryLabel
                if pending.contains(tag.id) {
                    let spinner = UIActivityIndicatorView(style: .medium)
                    spinner.startAnimating()
                    cell.accessoryView = spinner
                } else if assigned.contains(tag.id) {
                    cell.accessoryType = .checkmark
                }
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .create:
            promptNewTag()
        case .tags:
            guard case .loaded = state, !tags.isEmpty else { return }
            toggle(tags[indexPath.row])
        }
    }

    // MARK: - Actions

    private func toggle(_ tag: NKTag) {
        guard !pending.contains(tag.id) else { return }
        let wasAssigned = assigned.contains(tag.id)
        // Optimistic: flip now, revert on failure.
        if wasAssigned { assigned.remove(tag.id) } else { assigned.insert(tag.id) }
        pending.insert(tag.id)
        reloadTagsSection()
        Task {
            do {
                if wasAssigned {
                    try await client.removeTag(tag.id, fromFileId: photo.fileId)
                } else {
                    try await client.addTag(tag.id, toFileId: photo.fileId)
                }
            } catch {
                if wasAssigned { assigned.insert(tag.id) } else { assigned.remove(tag.id) }
                presentError(error)
            }
            pending.remove(tag.id)
            reloadTagsSection()
        }
    }

    private func promptNewTag() {
        let alert = UIAlertController(title: "New Tag", message: "Create a tag and add it to this photo.", preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Tag Name"
            $0.autocapitalizationType = .words
            $0.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            self.createAndAssign(name: name)
        })
        present(alert, animated: true)
    }

    private func createAndAssign(name: String) {
        Task {
            do {
                try await client.createTag(named: name)
                let all = try await client.availableTags()
                tags = all
                if let created = all.first(where: { $0.name == name }) {
                    try await client.addTag(created.id, toFileId: photo.fileId)
                    assigned.insert(created.id)
                }
                state = .loaded
                tableView.reloadData()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                presentError(error)
            }
        }
    }

    private func reloadTagsSection() {
        tableView.reloadSections(IndexSet(integer: Section.tags.rawValue), with: .none)
    }

    private func presentError(_ error: Error) {
        let message = (error as? GalleryError)?.userMessage ?? error.localizedDescription
        let alert = UIAlertController(title: "Couldn't Update Tag", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}

private extension UIColor {
    /// Parses a Nextcloud tag colour: an RGB hex string like `"FF0000"` or `"#FF0000"`.
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
