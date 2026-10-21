# AGENTS.md — EncameraCore

EncameraCore is a Swift package that builds for iOS 17 and macOS 14. Its tests run natively on the Mac through SwiftPM, with no simulator and no app host. That is the default way to test a change that only touches this package.

## Testing EncameraCore

```bash
cd EncameraCore

# Whole suite (~1 min)
CFFIXED_USER_HOME="$(mktemp -d)" swift test

# One class or one test
CFFIXED_USER_HOME="$(mktemp -d)" swift test --filter EncameraCoreTests.KeyFingerprintTests
CFFIXED_USER_HOME="$(mktemp -d)" swift test --filter 'EncameraCoreTests.KeyFingerprintTests/testFingerprintIsDeterministic'

# Build only
swift build
```

- **Always set `CFFIXED_USER_HOME`.** The tests write albums, indexes and caches to the standard user directories. On iOS those are the app's sandbox; on a Mac they are your real home folder.
- **Read the summary, not the exit code.** A skipped test still exits 0. Check for `Executed N tests, with 0 failures`.
- **About 15 tests skip under `swift test`.** They need the app's iCloud entitlements or iOS's own AVFoundation behaviour, and call `skipUnlessAppHosted(_:)` (`Tests/EncameraCoreTests/Support/AppHostedOnly.swift`). If your change touches one of those paths, also run the app-hosted bundle below.

## When to use the app-hosted bundle instead

The same test sources also compile into the `EncameraCoreTests` target of the Xcode project, hosted in the app and run on the iOS simulator. Use it when:

- the change touches code behind `#if os(iOS)` or `#if canImport(UIKit)` (camera, zoom, audio session, share sheet), which `swift test` on macOS does not compile;
- the test you care about calls `skipUnlessAppHosted`;
- you are checking what Xcode Cloud will run. The `Encamera` scheme's test action still runs every Core test there.

```bash
xcodebuild test -project Encamera.xcodeproj -scheme Encamera \
  -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:EncameraCoreTests
```

Run that from the repo root, and run `xcodegen generate` first if you added or removed files.

## Keeping the package Mac-buildable

- Don't `import UIKit` in `Sources/`. Use `PlatformImage` for images, and the `BackgroundExecution` and `AppLifecycleNotification` wrappers for background tasks and lifecycle events.
- Code that only makes sense on iOS goes behind `#if os(iOS)`. Presentation helpers (view controllers, settings deep links, alternate icons) belong in the app target, not here.
- A test that genuinely needs the app host calls `skipUnlessAppHosted("<why>")` at the top, so the Mac run reports a skip rather than a failure.
- After touching platform code, run `swift build` here and build the app for iOS. One passing doesn't prove the other.

Area guides with more rules: `Sources/EncameraCore/CloudKit/AGENTS.md` (sync and migration) and `../Documentation/multi-device-keys/AGENTS.md` (the key plane).
