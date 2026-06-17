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

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.color = .systemRed

        if indexPath.section == 0 {
            content.text = "Clear Local Cache"
            content.image = UIImage(systemName: "trash")
            content.imageProperties.tintColor = .systemRed
            if isClearing {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
        } else {
            content.text = "Sign Out"
            content.image = UIImage(systemName: "rectangle.portrait.and.arrow.right")
            content.imageProperties.tintColor = .systemRed
        }
        cell.contentConfiguration = content
        cell.selectionStyle = isClearing ? .none : .default
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0
            ? "Deletes the cached folder structure, thumbnails, and downloaded photos from this device. You'll stay signed in, and your library re-downloads as you browse."
            : nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isClearing else { return }
        if indexPath.section == 0 {
            confirmClearCache()
        } else {
            environment.signOut()
            tabs.isShowingSettings = false
        }
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
        if let popover = sheet.popoverPresentationController, let cell = tableView.cellForRow(at: IndexPath(row: 0, section: 0)) {
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
