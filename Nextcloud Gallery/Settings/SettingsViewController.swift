//
//  SettingsViewController.swift
//  Nextcloud Gallery
//
//  Account + on-device storage settings, presented as a sheet: clear the local
//  cache (without signing out) or sign out.
//

import UIKit

final class SettingsViewController: UITableViewController {
    private let environment: AppEnvironment
    private let tabs: TabsModel
    private var isClearing = false

    init(environment: AppEnvironment, tabs: TabsModel) {
        self.environment = environment
        self.tabs = tabs
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
    }

    // MARK: - Table

    private enum Section: Int, CaseIterable {
        case media, newTab, clearCache, signOut
    }

    private var account: String? { environment.credentials?.account }
    private var mediaFolderPath: String? { account.flatMap { MediaFolder.path(account: $0) } }
    private var hasMediaFolder: Bool { mediaFolderPath != nil }
    /// A friendly name for the current media folder ("Files (Root)" for the root).
    private var mediaFolderName: String {
        guard let path = mediaFolderPath else { return "Not Set" }
        if let client = environment.client, WebDAVPath.normalized(path) == WebDAVPath.normalized(client.filesRootPath) {
            return "Files (Root)"
        }
        return WebDAVPath.displayName(of: path)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .media: return hasMediaFolder ? 2 : 1
        case .newTab: return NewTabDestination.allCases.count
        case .clearCache, .signOut: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .media: return "Media"
        case .newTab: return "New Tab Opens To"
        case .clearCache, .signOut: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        switch Section(rawValue: indexPath.section)! {
        case .media:
            if indexPath.row == 0 {
                content.text = "Media Folder"
                content.secondaryText = mediaFolderName
                content.image = UIImage(systemName: "photo.stack")
                cell.accessoryType = .disclosureIndicator
            } else {
                content.text = "Clear Media Folder"
                content.image = UIImage(systemName: "xmark.circle")
                content.textProperties.color = .systemRed
                content.imageProperties.tintColor = .systemRed
            }
        case .newTab:
            let destination = NewTabDestination.allCases[indexPath.row]
            content.text = destination.label
            content.image = UIImage(systemName: destination.symbol)
            cell.accessoryType = destination == NewTabDestination.preference ? .checkmark : .none
            cell.selectionStyle = .default
        case .clearCache:
            content.text = "Clear Local Cache"
            content.image = UIImage(systemName: "trash")
            content.textProperties.color = .systemRed
            content.imageProperties.tintColor = .systemRed
            if isClearing {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
            cell.selectionStyle = isClearing ? .none : .default
        case .signOut:
            content.text = "Sign Out"
            content.image = UIImage(systemName: "rectangle.portrait.and.arrow.right")
            content.textProperties.color = .systemRed
            content.imageProperties.tintColor = .systemRed
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .media:
            return "Photos in this folder open as the Home gallery; you can also browse it as a folder."
        case .newTab:
            return "“Current Location” opens new tabs with a copy of your current navigation, so you can still go back."
        case .clearCache:
            return "Deletes the cached folder structure, thumbnails, and downloaded photos from this device. You'll stay signed in, and your library re-downloads as you browse."
        case .signOut:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isClearing else { return }
        switch Section(rawValue: indexPath.section)! {
        case .media:
            if indexPath.row == 0 { presentFolderPicker() } else { clearMediaFolder() }
        case .newTab:
            NewTabDestination.preference = NewTabDestination.allCases[indexPath.row]
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
        case .clearCache:
            confirmClearCache()
        case .signOut:
            environment.signOut()
            tabs.isShowingSettings = false
        }
    }

    private func presentFolderPicker() {
        guard let client = environment.client else { return }
        let account = client.credentials.account
        let picker = FolderPickerViewController(folderPath: client.filesRootPath, title: "Files", isRoot: true, client: client) { [weak self] path, _ in
            MediaFolder.setPath(path, account: account)
            self?.presentedViewController?.dismiss(animated: true)
            self?.tableView.reloadSections(IndexSet(integer: Section.media.rawValue), with: .automatic)
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    private func clearMediaFolder() {
        guard let account else { return }
        MediaFolder.setPath(nil, account: account)
        tableView.reloadSections(IndexSet(integer: Section.media.rawValue), with: .automatic)
    }

    // MARK: - Actions

    @objc private func done() {
        guard !isClearing else { return }
        tabs.isShowingSettings = false
    }

    private func confirmClearCache() {
        let sheet = UIAlertController(
            title: "Clear Local Cache?",
            message: "This deletes all cached folders, thumbnails, and downloaded photos from this device. You'll stay signed in.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Clear Cache", style: .destructive) { [weak self] _ in
            self?.clearCache()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // iPad: anchor the action sheet to the row.
        if let popover = sheet.popoverPresentationController, let cell = tableView.cellForRow(at: IndexPath(row: 0, section: Section.clearCache.rawValue)) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func clearCache() {
        isClearing = true
        isModalInPresentation = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        tableView.reloadData()
        Task {
            await environment.clearLocalCache()
            isClearing = false
            isModalInPresentation = false
            navigationItem.rightBarButtonItem?.isEnabled = true
            tableView.reloadData()
        }
    }
}
