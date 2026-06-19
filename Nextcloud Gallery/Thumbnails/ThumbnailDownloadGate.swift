//
//  ThumbnailDownloadGate.swift
//  Nextcloud Gallery
//
//  Bounds and prioritizes concurrent thumbnail downloads so the images the user is
//  looking at load ahead of prefetched or scrolled-past ones.
//

import Foundation

/// How urgently a thumbnail is needed, used to order downloads through
/// ``ThumbnailDownloadGate``. On-screen cells request `.visible`; the grid
/// prefetcher and the warming crawler request `.prefetch`.
enum ThumbnailPriority {
    case visible
    case prefetch
}

/// A bounded, priority-ordered, cancellable async gate around thumbnail downloads.
///
/// It limits how many downloads run at once and, when full, hands a freed slot to a
/// waiting `.visible` request before any `.prefetch` one — so bandwidth follows what
/// the user is actually looking at. A waiter whose task is cancelled (its cell
/// scrolled away) leaves the queue without ever taking a slot, so work for
/// no-longer-visible items never reaches the network.
///
/// Keep the limit at or below `httpMaximumConnectionsPerHost` so this gate — not
/// URLSession's opaque FIFO connection queue — is what actually orders the work.
actor ThumbnailDownloadGate {
    private let limit: Int
    private var active = 0

    private final class Waiter {
        let high: Bool
        var continuation: CheckedContinuation<Void, Error>?
        init(high: Bool) { self.high = high }
    }
    private var waiters: [Waiter] = []

    init(limit: Int) { self.limit = limit }

    /// Suspends until a slot is free, then occupies it. A `high` request jumps ahead
    /// of queued non-`high` ones (FIFO within a tier). Throws `CancellationError` if
    /// the awaiting task is cancelled while waiting — in which case it never holds a
    /// slot and must not call ``release()``.
    func acquire(high: Bool) async throws {
        if active < limit {
            active += 1
            return
        }
        let waiter = Waiter(high: high)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Already cancelled before we suspended: resolve now, don't enqueue,
                // or the slot-handoff below would never reach us.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter.continuation = continuation
                if high, let i = waiters.firstIndex(where: { !$0.high }) {
                    waiters.insert(waiter, at: i)
                } else {
                    waiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.drop(waiter) }
        }
    }

    /// Releases a held slot, handing it straight to the highest-priority waiter (so
    /// `active` stays constant on handoff) or freeing it if none are waiting.
    func release() {
        guard !waiters.isEmpty else {
            active -= 1
            return
        }
        let next = waiters.removeFirst()
        let continuation = next.continuation
        next.continuation = nil
        continuation?.resume()
    }

    private func drop(_ waiter: Waiter) {
        guard let index = waiters.firstIndex(where: { $0 === waiter }) else { return }
        waiters.remove(at: index)
        let continuation = waiter.continuation
        waiter.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}
