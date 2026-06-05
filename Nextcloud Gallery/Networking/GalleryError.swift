//
//  GalleryError.swift
//  Nextcloud Gallery
//
//  Typed errors surfaced by the networking layer.
//

import Foundation
import NextcloudKit

/// Errors thrown by ``NextcloudClient`` and friends, translated from `NKError`.
nonisolated enum GalleryError: Error, Sendable, Equatable {
    case notAuthorized
    case cancelled
    case noData
    case invalidServerURL
    case loginFailed
    case network(code: Int, description: String)

    init(_ nkError: NKError) {
        switch nkError.errorCode {
        case 401, 403:
            self = .notAuthorized
        case NSURLErrorCancelled, -999:
            self = .cancelled
        default:
            self = .network(code: nkError.errorCode, description: nkError.errorDescription)
        }
    }
}

extension GalleryError {
    /// A short, user-facing message.
    var userMessage: String {
        switch self {
        case .notAuthorized: "You're not authorized. Try signing in again."
        case .cancelled: "The request was cancelled."
        case .noData: "The server returned no data."
        case .invalidServerURL: "That doesn't look like a valid server address."
        case .loginFailed: "Sign in failed. Please try again."
        case let .network(code, description):
            description.isEmpty ? "Network error (\(code))." : description
        }
    }
}
