//
//  FolderPickerViewController.swift
//  Nextcloud Gallery
//
//  Browses the folder tree to pick one folder — used to set the Media folder. Each
//  level lists its subfolders; tapping one drills in, and "Choose" selects the level
//  you're on. The caller supplies `onChoose` (which sets the folder and dismisses).
//

import UIKit
import NextcloudKit

final class FolderPickerViewController: UITableViewController {
    private let folderPath: String
    private let folderTitle: String
    private let isRoot: Bool
    private let client: NextcloudClient
    /// Called with the chosen folder's `(path, displayTitle)`.
    private let onChoose: (String, String) -> Void

    private enum LoadState { case loading, loaded, failed(String) }
    private var subfolders: [(path: String, name: String)] = []
    private var state: LoadState = .loading

    init(folderPath: String, title: String, isRoot: Bool, client: NextcloudClient, onChoose: @escaping (String, String) -> Void) {
        self.folderPath = folderPath
        self.folderTitle = title
        self.isRoot = isRoot
        self.client = client
        self.onChoose = onChoose
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = folderTitle
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Choose", style: .done, target: self, action: #selector(choose))
        if isRoot {
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        }
        Task { await load() }
    }

    private func load() async {
        state = .loading
        tableView.reloadData()
        do {
            let files = try await client.listFolder(at: folderPath)
            subfolders = files
                .filter { $0.directory }
                .map { (WebDAVPath.normalized($0.serverUrl + "/" + $0.fileName), $0.fileName) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            state = .loaded
        } catch {
            state = .failed((error as? GalleryError)?.userMessage ?? error.localizedDescription)
        }
        tableView.reloadData()
    }

    @objc private func choose() { onChoose(folderPath, folderTitle) }
    @objc private func cancel() { dismiss(animated: true) }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if case .loaded = state { return max(subfolders.count, 1) }
        return 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { "Folders" }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Open a subfolder, or tap Choose to use “\(folderTitle)”."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        switch state {
        case .loading:
            content.text = "Loading…"
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        case .failed(let message):
            content.text = message
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        case .loaded where subfolders.isEmpty:
            content.text = "No subfolders"
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        case .loaded:
            content.text = subfolders[indexPath.row].name
            content.image = UIImage(systemName: "folder")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .loaded = state, !subfolders.isEmpty else { return }
        let subfolder = subfolders[indexPath.row]
        let next = FolderPickerViewController(folderPath: subfolder.path, title: subfolder.name, isRoot: false, client: client, onChoose: onChoose)
        navigationController?.pushViewController(next, animated: true)
    }
}
