//
//  NetworkMonitor.swift
//  Nextcloud Gallery
//
//  Publishes whether the network is suitable for proactive bulk transfers.
//

import Foundation
import Network
import Observation

/// Observes the network path and publishes ``isWiFi`` — true only when it's
/// appropriate to do proactive, bulk work (connected, not cellular/hotspot, not
/// Low Data Mode). Foreground taps ignore this and load on any network.
@Observable
@MainActor
final class NetworkMonitor {
    private(set) var isWiFi = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "app.lyons.Nextcloud-Gallery.networkmonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Apple-blessed signal for "OK to do background bulk transfer".
            let suitable = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor [weak self] in
                self?.isWiFi = suitable
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
