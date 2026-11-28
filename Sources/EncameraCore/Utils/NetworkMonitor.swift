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
///
/// The path handler writes on the monitor's own queue and readers sit on any
/// thread, so every flag is read and written under `lock`.
///
/// Right after the monitor starts, `NWPathMonitor.currentPath` is often still
/// unsatisfied on a connected device, and the first real path arrives through
/// the update handler some milliseconds later. The synchronous accessors read
/// whatever is recorded now; a reader that must not mistake that start-up
/// value for being offline awaits `knownState(timeout:)` instead.
public final class NetworkMonitor: @unchecked Sendable {

    public static let shared = NetworkMonitor()

    /// Posted on the main queue when `isConnected` or `isOnUnmeteredNetwork`
    /// changes. Not posted when a path update leaves both as they were.
    public static let pathDidChange = Notification.Name("NetworkMonitor.pathDidChange")

    /// The flags derived from one network path.
    public struct State: Equatable, Sendable {
        /// The path is satisfied.
        public var isConnected: Bool
        /// The path uses a Wi-Fi interface (Personal Hotspot included).
        public var isOnWiFi: Bool
        /// The path uses a cellular interface.
        public var isOnCellular: Bool
        /// The path is satisfied and neither expensive nor constrained: Wi-Fi
        /// or wired Ethernet, but not Personal Hotspot, cellular or Low Data
        /// Mode.
        public var isOnUnmeteredNetwork: Bool

        public init(isConnected: Bool, isOnWiFi: Bool, isOnCellular: Bool, isOnUnmeteredNetwork: Bool) {
            self.isConnected = isConnected
            self.isOnWiFi = isOnWiFi
            self.isOnCellular = isOnCellular
            self.isOnUnmeteredNetwork = isOnUnmeteredNetwork
        }

        public static let offline = State(isConnected: false, isOnWiFi: false,
                                          isOnCellular: false, isOnUnmeteredNetwork: false)
    }

    /// A network path a test forces in place of the real one.
    public enum ForcedPath: String, Sendable {
        case wifi
        case cellular
        case offline

        var state: State {
            switch self {
            case .wifi:
                return NetworkMonitor.state(status: .satisfied, isExpensive: false, isConstrained: false,
                                            usesWiFi: true, usesCellular: false)
            case .cellular:
                return NetworkMonitor.state(status: .satisfied, isExpensive: true, isConstrained: false,
                                            usesWiFi: false, usesCellular: true)
            case .offline:
                return .offline
            }
        }
    }

    private let monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.encamera.networkmonitor", qos: .utility)
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var pathState: State = .offline
    private var forcedPath: ForcedPath?
    /// Whether `pathState` reflects a real path: one the update handler
    /// delivered, or a satisfied path read at start.
    private var isPathKnown: Bool
    /// The `knownState(timeout:)` callers waiting for the path to be known.
    private var knownStateWaiters: [UUID: CheckedContinuation<State, Never>] = [:]

    /// How long `knownState(timeout:)` waits by default for the first path.
    public static let defaultKnownStateTimeout: TimeInterval = 1.5

    /// Whether the device currently has a usable network connection.
    public var isConnected: Bool { currentState.isConnected }

    /// Whether the current connection is over cellular data.
    public var isOnCellular: Bool { currentState.isOnCellular }

    /// Whether the current connection is unmetered: satisfied, not expensive
    /// and not constrained. Wired Ethernet counts; Personal Hotspot and Low
    /// Data Mode don't.
    public var isOnUnmeteredNetwork: Bool { currentState.isOnUnmeteredNetwork }

    /// The forced path's state while one is set, otherwise the real path's.
    public var currentState: State {
        lock.withLock { forcedPath?.state ?? pathState }
    }

    private init() {
        notificationCenter = .default
        isPathKnown = false
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.updateState(from: path)
        }
        monitor.start(queue: queue)

        let startPath = monitor.currentPath
        recordStartPathState(Self.state(from: startPath), isKnown: startPath.status == .satisfied)
    }

    /// A monitor that watches no real path, for tests that feed it states
    /// through `update(to:)`. With `isPathKnown` false, `knownState(timeout:)`
    /// waits for the first `update(to:)` as it waits for the first real path.
    init(testingWith notificationCenter: NotificationCenter, initialState: State = .offline, isPathKnown: Bool = true) {
        self.monitor = nil
        self.notificationCenter = notificationCenter
        self.pathState = initialState
        self.isPathKnown = isPathKnown
    }

    /// The flags for a path with these properties.
    public static func state(status: NWPath.Status,
                             isExpensive: Bool,
                             isConstrained: Bool,
                             usesWiFi: Bool,
                             usesCellular: Bool) -> State {
        let isConnected = status == .satisfied
        return State(isConnected: isConnected,
                     isOnWiFi: usesWiFi,
                     isOnCellular: usesCellular,
                     isOnUnmeteredNetwork: isConnected && !isExpensive && !isConstrained)
    }

    /// Forces every reader to see `path` until it is cleared with `nil`.
    /// Posts `pathDidChange` when the visible state changes.
    public func force(_ path: ForcedPath?) {
        swapState { forcedPath = path }
    }

    /// The state readers see once the path is known: at once when a path
    /// update has arrived, a satisfied path was read at start, or a path is
    /// forced; otherwise after the first path update, or after `timeout`
    /// seconds with whatever is recorded then. Does not block the caller's
    /// thread while it waits.
    public func knownState(timeout: TimeInterval = NetworkMonitor.defaultKnownStateTimeout) async -> State {
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let stateNow: State? = lock.withLock {
                if isPathKnown || forcedPath != nil { return forcedPath?.state ?? pathState }
                knownStateWaiters[waiterID] = continuation
                return nil
            }
            if let stateNow {
                continuation.resume(returning: stateNow)
                return
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                resumeKnownStateWaiterAfterTimeout(waiterID)
            }
        }
    }

    private func resumeKnownStateWaiterAfterTimeout(_ waiterID: UUID) {
        let (waiter, state) = lock.withLock {
            (knownStateWaiters.removeValue(forKey: waiterID), forcedPath?.state ?? pathState)
        }
        waiter?.resume(returning: state)
    }

    private static func state(from path: NWPath) -> State {
        state(status: path.status,
              isExpensive: path.isExpensive,
              isConstrained: path.isConstrained,
              usesWiFi: path.usesInterfaceType(.wifi),
              usesCellular: path.usesInterfaceType(.cellular))
    }

    /// Updates the network state properties from the given path.
    private func updateState(from path: NWPath) {
        update(to: Self.state(from: path))
    }

    /// Records the path read right after the monitor starts, unless the
    /// update handler already delivered one.
    private func recordStartPathState(_ state: State, isKnown: Bool) {
        swapState {
            guard !isPathKnown else { return }
            pathState = state
            isPathKnown = isKnown
        }
    }

    /// Records the real path's state. Posts `pathDidChange` when the visible
    /// state changes.
    func update(to state: State) {
        swapState {
            pathState = state
            isPathKnown = true
        }
    }

    /// Applies `change` under the lock, resumes the `knownState(timeout:)`
    /// waiters once the path is known, and posts `pathDidChange` when the
    /// visible state changed.
    private func swapState(_ change: () -> Void) {
        let (old, new, waiters) = lock.withLock { () -> (State, State, [CheckedContinuation<State, Never>]) in
            let old = forcedPath?.state ?? pathState
            change()
            var waiters: [CheckedContinuation<State, Never>] = []
            if isPathKnown || forcedPath != nil {
                waiters = Array(knownStateWaiters.values)
                knownStateWaiters.removeAll()
            }
            return (old, forcedPath?.state ?? pathState, waiters)
        }
        for waiter in waiters { waiter.resume(returning: new) }
        guard old.isConnected != new.isConnected
                || old.isOnUnmeteredNetwork != new.isOnUnmeteredNetwork else { return }
        let center = notificationCenter
        DispatchQueue.main.async {
            center.post(name: Self.pathDidChange, object: self)
        }
    }

    deinit {
        monitor?.cancel()
    }
}
