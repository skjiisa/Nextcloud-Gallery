//
//  PhotoSaver.swift
//  Nextcloud Gallery
//
//  Saves a photo to the user's iOS photo library (add-only).
//

import SwiftUI
import Photos
import Observation

/// Downloads the original file (reusing ``FullImageStore``) and adds it to the
/// Photos library using add-only authorization (no read access requested).
@Observable
@MainActor
final class PhotoSaver {
    enum Status: Equatable {
        case idle
        case saving
        case saved
        case denied
        case failed(String)
    }

    private(set) var status: Status = .idle

    func save(photo: PhotoItem, client: NextcloudClient?, store: FullImageStore) async {
        guard let client else { return }

        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            status = .denied
            return
        }

        status = .saving
        do {
            let url = try await store.load(
                ocId: photo.ocId, etag: photo.etag, fileName: photo.fileName,
                serverPath: photo.serverPath, client: client
            )
            let fileName = photo.fileName
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = fileName
                request.addResource(with: .photo, fileURL: url, options: options)
            }
            status = .saved
        } catch {
            status = .failed((error as? GalleryError)?.userMessage ?? error.localizedDescription)
        }
    }

    /// Clears a terminal status (e.g. after dismissing an alert).
    func reset() {
        status = .idle
    }

    var errorMessage: String? {
        switch status {
        case .denied: "Photo access was denied. You can enable it in Settings."
        case let .failed(message): message
        default: nil
        }
    }
}
