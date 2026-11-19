//
//  MediaLoaderServiceThreadingTests.swift
//  EncameraCoreTests
//
//  `MediaLoaderService` runs off the main actor. PhotoKit calls its photo
//  handler on the main queue, so the loader writes the bytes after the
//  handler returns, through `persistImageData`, which must not run on main.
//

import XCTest
@testable import EncameraCore

final class MediaLoaderServiceThreadingTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLoaderServiceThreadingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    @MainActor
    func testPersistImageDataWritesOffMainWhenCalledFromMain() async throws {
        XCTAssertTrue(Thread.isMainThread, "the test starts on main")
        let probe = ThreadRecorder()
        let url = directory.appendingPathComponent("photo.jpeg")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })

        try await MediaLoaderService.persistImageData(bytes, to: url) { data, url in
            probe.record()
            try data.write(to: url)
        }

        XCTAssertEqual(probe.calls, [false], "the write ran once, off the main thread")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testPersistImageDataPropagatesWriteError() async throws {
        let url = directory.appendingPathComponent("photo.jpeg")
        struct DiskFull: Error {}

        do {
            try await MediaLoaderService.persistImageData(Data(repeating: 1, count: 1024), to: url) { data, url in
                // Leave half the bytes behind, as an interrupted write would.
                try data.prefix(512).write(to: url)
                throw DiskFull()
            }
            XCTFail("expected the write error")
        } catch is DiskFull {
            // expected
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no partial file is left behind")
    }

    func testMediaLoaderServiceIsUsableFromNonisolatedContext() async {
        // Compiles only while `MediaLoaderService` is not main-actor isolated
        // and is Sendable as an `ImportMediaLoading`.
        let ranOnMain = await Task.detached { () -> Bool in
            let loader: any ImportMediaLoading = MediaLoaderService()
            _ = loader
            return currentThreadIsMain()
        }.value
        XCTAssertFalse(ranOnMain)
    }
}

/// `Thread.isMainThread` read from a synchronous function, since async code
/// may not read it directly.
private func currentThreadIsMain() -> Bool { Thread.isMainThread }

private final class ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []

    var calls: [Bool] { lock.withLock { recorded } }

    func record() {
        lock.withLock { recorded.append(Thread.isMainThread) }
    }
}
