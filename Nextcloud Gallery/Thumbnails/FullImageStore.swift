//
//  FullImageStore.swift
//  Nextcloud Gallery
//
//  Disk cache for full-resolution photo files (viewer zoom + save to Photos).
//

import Foundation

/// Downloads and caches original photo files on disk, coalescing concurrent
/// requests. Shared by the viewer (full-res display) and the Photos saver so a
/// photo is only downloaded once.
actor FullImageStore {
    private let directory: URL
    private var inFlight: [String: Task<URL, Error>] = [:]

    init() {
        var base = URL.applicationSupportDirectory.appending(path: "FullImages", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)
        directory = base
    }

    /// Returns a local file URL for the original file, downloading if needed.
    func load(
        ocId: String,
        etag: String,
        fileName: String,
        serverPath: String,
        client: NextcloudClient,
        queue: DispatchQueue = .main
    ) async throws -> URL {
        let safeEtag = etag.replacing("/", with: "-").replacing("\"", with: "")
        let ext = URL(filePath: fileName).pathExtension
        let name = ext.isEmpty ? "\(ocId)_\(safeEtag)" : "\(ocId)_\(safeEtag).\(ext)"
        let url = directory.appending(path: name)

        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let existing = inFlight[name] { return try await existing.value }

        let task = Task<URL, Error> {
            try await client.downloadFile(serverPath: serverPath, toPath: url.path, queue: queue)
            return url
        }
        inFlight[name] = task
        do {
            let result = try await task.value
            inFlight[name] = nil
            return result
        } catch {
            inFlight[name] = nil
            throw error
        }
    }

    /// Evicts oldest original files to keep the cache under a size budget.
    func reap(maxBytes: Int) {
        DiskCacheReaper.reap(directory: directory, maxBytes: maxBytes)
    }
}
