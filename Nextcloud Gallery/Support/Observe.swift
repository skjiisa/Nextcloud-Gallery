//
//  Observe.swift
//  Nextcloud Gallery
//
//  Bridges `@Observable` state into UIKit. SwiftUI re-evaluates a `body` whenever
//  any observed property it read changes; UIKit has no equivalent, so this gives a
//  controller the same "re-run my render closure when the state it touched
//  mutates" behavior, built on `withObservationTracking`.
//

import Foundation
import Observation

/// A cancellable observation registration. Held by the observer (typically a
/// view controller); deinit/`cancel()` stops further callbacks.
@MainActor
final class ObservationToken {
    private var isCancelled = false
    func cancel() { isCancelled = true }
    var isActive: Bool { !isCancelled }
}

/// Runs `render` immediately, then re-runs it on the main actor whenever any
/// `@Observable` property it reads is mutated — re-arming the tracking each time.
///
/// `render` should both *read* the observable state and *apply* it to the UI: the
/// read is what registers the dependency, exactly like a SwiftUI `body`. Keep it
/// idempotent (safe to run repeatedly). The returned token must be retained for
/// observation to continue.
@MainActor
@discardableResult
func observeChanges(_ render: @escaping @MainActor () -> Void) -> ObservationToken {
    let token = ObservationToken()
    func arm() {
        guard token.isActive else { return }
        withObservationTracking {
            render()
        } onChange: {
            // `onChange` fires synchronously inside the mutation (before the new
            // value is committed) and on the mutating thread. Hop to the main actor
            // on the next tick so `render` reads fully-updated state and re-arms.
            Task { @MainActor in arm() }
        }
    }
    arm()
    return token
}
