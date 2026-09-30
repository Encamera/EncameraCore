//
//  DeviceFreeSpaceTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

final class DeviceFreeSpaceTests: XCTestCase {

    func testLiveProviderReturnsPositiveValueOnSimulator() throws {
        let bytes = try XCTUnwrap(LiveDeviceFreeSpace().availableBytesForImport())

        XCTAssertGreaterThan(bytes, 0)
    }

    func testFixedProviderReturnsInjectedValue() {
        XCTAssertEqual(FixedDeviceFreeSpace(1_000).availableBytesForImport(), 1_000)
        XCTAssertNil(FixedDeviceFreeSpace(nil as Int64?).availableBytesForImport())
    }

    func testFixedProviderClosureCanShrinkBetweenCalls() {
        let values = LockedQueue<Int64>([300, 200, 100])
        let provider = FixedDeviceFreeSpace { values.next() }

        XCTAssertEqual(provider.availableBytesForImport(), 300)
        XCTAssertEqual(provider.availableBytesForImport(), 200)
        XCTAssertEqual(provider.availableBytesForImport(), 100)
    }
}

/// A thread-safe queue of values handed out one per call.
private final class LockedQueue<Value>: @unchecked Sendable {
    private var values: [Value]
    private let lock = NSLock()

    init(_ values: [Value]) {
        self.values = values
    }

    func next() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? nil : values.removeFirst()
    }
}
