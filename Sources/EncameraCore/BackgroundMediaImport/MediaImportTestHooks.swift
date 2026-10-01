//
//  MediaImportTestHooks.swift
//  EncameraCore
//
//  UI-test-only fault-injection points for `MediaImportHandler`. All hooks
//  default to inert values; the app sets them from launch arguments inside
//  `UITestMode.setupIfNeeded()` so production builds are unaffected.
//

import Foundation

/// Test-only configuration `MediaImportHandler` consults before saving each item,
/// so a UI test can cancel an import partway through or fail specific items
/// deterministically.
public enum MediaImportTestHooks {
    /// Sleep applied before each item is saved. Long enough to let a test tap
    /// Cancel after a known number of items have landed.
    public static var itemDelayMs: Int = 0

    /// Zero-based item indexes, within one import, whose save throws
    /// `injectedFailure` instead of running.
    public static var failItemIndexes: Set<Int> = []

    public struct InjectedFailure: Error {}

    static func beforeSavingItem(at index: Int) async throws {
        if itemDelayMs > 0 {
            try await Task.sleep(nanoseconds: UInt64(itemDelayMs) * 1_000_000)
        }
        if failItemIndexes.contains(index) {
            throw InjectedFailure()
        }
    }
}
