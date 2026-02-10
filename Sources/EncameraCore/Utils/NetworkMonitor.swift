//
//  NetworkMonitor.swift
//  EncameraCore
//
//  Created on 06.02.26.
//

import Foundation
import Network

/// Monitors the device's network connectivity and provides information about the connection type.
/// Uses `NWPathMonitor` from the Network framework for reliable, real-time path detection.
public final class NetworkMonitor {

    public static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.encamera.networkmonitor", qos: .utility)

    /// Whether the device currently has a usable network connection.
    public private(set) var isConnected: Bool = false

    /// Whether the current connection is over WiFi.
    public private(set) var isOnWiFi: Bool = false

    /// Whether the current connection is over cellular data.
    public private(set) var isOnCellular: Bool = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.updateState(from: path)
        }
        monitor.start(queue: queue)

        // Seed state synchronously from the current path so properties
        // are correct even before the first async pathUpdateHandler callback.
        updateState(from: monitor.currentPath)
    }

    /// Updates the network state properties from the given path.
    private func updateState(from path: NWPath) {
        isConnected = path.status == .satisfied
        isOnWiFi = path.usesInterfaceType(.wifi)
        isOnCellular = path.usesInterfaceType(.cellular)
    }

    deinit {
        monitor.cancel()
    }
}
