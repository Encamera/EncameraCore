//
//  NetworkMonitorTests.swift
//  EncameraCoreTests
//
//  Which paths count as unmetered, and when `pathDidChange` is posted. Every
//  state is fed in; nothing reads the host Mac's network.
//

import XCTest
import Network
@testable import EncameraCore

final class NetworkMonitorTests: XCTestCase {

    func testSatisfiedCheapUnconstrainedPathIsUnmetered() {
        let wifi = NetworkMonitor.state(status: .satisfied, isExpensive: false, isConstrained: false,
                                        usesWiFi: true, usesCellular: false)
        XCTAssertTrue(wifi.isConnected)
        XCTAssertTrue(wifi.isOnUnmeteredNetwork)

        let ethernet = NetworkMonitor.state(status: .satisfied, isExpensive: false, isConstrained: false,
                                            usesWiFi: false, usesCellular: false)
        XCTAssertTrue(ethernet.isOnUnmeteredNetwork, "wired Ethernet counts as Wi-Fi")
        XCTAssertFalse(ethernet.isOnWiFi)
    }

    func testExpensivePathIsNotUnmetered() {
        let hotspot = NetworkMonitor.state(status: .satisfied, isExpensive: true, isConstrained: false,
                                           usesWiFi: true, usesCellular: false)
        XCTAssertTrue(hotspot.isConnected)
        XCTAssertTrue(hotspot.isOnWiFi, "isOnWiFi keeps its interface meaning for its old callers")
        XCTAssertFalse(hotspot.isOnUnmeteredNetwork)

        let cellular = NetworkMonitor.state(status: .satisfied, isExpensive: true, isConstrained: false,
                                            usesWiFi: false, usesCellular: true)
        XCTAssertTrue(cellular.isConnected)
        XCTAssertTrue(cellular.isOnCellular)
        XCTAssertFalse(cellular.isOnUnmeteredNetwork)
    }

    func testConstrainedPathIsNotUnmetered() {
        let lowDataMode = NetworkMonitor.state(status: .satisfied, isExpensive: false, isConstrained: true,
                                               usesWiFi: true, usesCellular: false)
        XCTAssertTrue(lowDataMode.isConnected)
        XCTAssertFalse(lowDataMode.isOnUnmeteredNetwork)
    }

    func testUnsatisfiedPathIsNeitherConnectedNorUnmetered() {
        for status in [NWPath.Status.unsatisfied, .requiresConnection] {
            let state = NetworkMonitor.state(status: status, isExpensive: false, isConstrained: false,
                                             usesWiFi: true, usesCellular: false)
            XCTAssertFalse(state.isConnected, "\(status)")
            XCTAssertFalse(state.isOnUnmeteredNetwork, "\(status)")
        }
    }

    func testPathDidChangePostedOnlyOnChange() {
        let center = NotificationCenter()
        let monitor = NetworkMonitor(testingWith: center)
        let wifi = NetworkMonitor.ForcedPath.wifi.state
        let cellular = NetworkMonitor.ForcedPath.cellular.state

        var posts = 0
        let token = center.addObserver(forName: NetworkMonitor.pathDidChange, object: monitor, queue: nil) { _ in
            posts += 1
        }
        defer { center.removeObserver(token) }

        monitor.update(to: wifi)
        monitor.update(to: wifi)
        drainMainQueue()
        XCTAssertEqual(posts, 1, "the same state twice posts once")

        var hotspotWiFi = wifi
        hotspotWiFi.isOnWiFi = false
        monitor.update(to: hotspotWiFi)
        drainMainQueue()
        XCTAssertEqual(posts, 1, "a change to neither isConnected nor isOnUnmeteredNetwork posts nothing")

        monitor.update(to: cellular)
        drainMainQueue()
        XCTAssertEqual(posts, 2, "losing Wi-Fi posts")

        monitor.update(to: .offline)
        drainMainQueue()
        XCTAssertEqual(posts, 3, "losing the connection posts")
    }

    func testForcedCellularOverride() {
        let center = NotificationCenter()
        let monitor = NetworkMonitor(testingWith: center, initialState: NetworkMonitor.ForcedPath.wifi.state)
        XCTAssertTrue(monitor.isOnUnmeteredNetwork)

        monitor.force(.cellular)
        XCTAssertTrue(monitor.isConnected)
        XCTAssertFalse(monitor.isOnUnmeteredNetwork)

        monitor.update(to: NetworkMonitor.ForcedPath.wifi.state)
        XCTAssertFalse(monitor.isOnUnmeteredNetwork, "a real path update doesn't lift the override")

        monitor.force(nil)
        XCTAssertTrue(monitor.isOnUnmeteredNetwork)
    }

    func testConcurrentReadsAndWritesAreSafe() {
        let monitor = NetworkMonitor(testingWith: NotificationCenter())
        let states = [NetworkMonitor.ForcedPath.wifi.state, NetworkMonitor.ForcedPath.cellular.state, .offline]
        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            if index.isMultiple(of: 2) {
                monitor.update(to: states[index % states.count])
            } else {
                _ = monitor.isOnUnmeteredNetwork
                _ = monitor.isConnected
            }
        }
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }
}
