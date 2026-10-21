import XCTest

/// Skips the calling test outside the app-hosted iOS `EncameraCoreTests`
/// bundle, for tests that need what only that host provides: the app's
/// iCloud entitlements, or iOS's own AVFoundation behaviour. The native macOS
/// `swift test` run reports them as skipped rather than failed.
func skipUnlessAppHosted(_ reason: String) throws {
    #if !os(iOS)
    throw XCTSkip("Runs only in the app-hosted iOS bundle: \(reason)")
    #endif
}
