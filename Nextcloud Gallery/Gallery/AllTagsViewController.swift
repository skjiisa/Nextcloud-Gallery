//
//  AllTagsViewController.swift
//  Nextcloud Gallery
//
//  The "See All" destination for Home's Tags strip: every system tag in a list.
//  Tapping one opens a gallery of files carrying it via the ``GalleryNavigator``.
//

import UIKit
import NextcloudKit

final class AllTagsViewController: UITableViewController {
    private let client: NextcloudClient
    private weak var navigator: GalleryNavigator?

    private enum LoadState { case loading, loaded, failed(String) }
    private var tags: [NKTag] = []
    private var state: LoadState = .loading
    private var didInitialLoad = false

    init(client: NextcloudClient, navigator: GalleryNavigator?) {
        self.client = client
        self.navigator = navigator
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Tags"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !didInitialLoad {
            didInitialLoad = true
            Task { await load() }
        }
    }

    private func load() async {
        state = .loading
        tableView.reloadData()
        do {
            tags = try await client.availableTags()
            state = .loaded
        } catch {
            state = .failed((error as? GalleryError)?.userMessage ?? error.localizedDescription)
        }
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if case .loaded = state { return max(tags.count, 1) }
        return 1
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
        case .loaded where tags.isEmpty:
            content.text = "No tags"
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        case .loaded:
            let tag = tags[indexPath.row]
            content.text = tag.name
            content.image = UIImage(systemName: "tag.fill")
            content.imageProperties.tintColor = tag.color.flatMap(UIColor.init(hex:)) ?? .secondaryLabel
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .loaded = state, !tags.isEmpty else { return }
        let tag = tags[indexPath.row]
        navigator?.openTag(id: tag.id, name: tag.name)
    }
}
