//
//  iCloudStorageModelRootURLTests.swift
//  EncameraCoreTests
//
//  `iCloudStorageModel.rootURL` when the device has an iCloud account but its
//  ubiquity container URL is nil. `rootURL` used to `fatalError` there, which
//  crashed every launch right after unlock.
//

import XCTest
@testable import EncameraCore

final class iCloudStorageModelRootURLTests: XCTestCase {

    private var originalContainerSource: iCloudStorageModel.ContainerSource!
    private var originalContainerOverride: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalContainerSource = iCloudStorageModel.containerSource
        originalContainerOverride = iCloudStorageModel.testContainerRootOverride
        iCloudStorageModel.testContainerRootOverride = nil
    }

    override func tearDownWithError() throws {
        iCloudStorageModel.containerSource = originalContainerSource
        iCloudStorageModel.testContainerRootOverride = originalContainerOverride
        try super.tearDownWithError()
    }

    private func simulateSignedInAccountWithoutContainer() {
        iCloudStorageModel.containerSource = .init(hasIdentityToken: { true },
                                                   containerURL: { nil })
    }

    func testRootURLDoesNotTrapWhenTheContainerIsUnavailable() throws {
        simulateSignedInAccountWithoutContainer()

        let root = iCloudStorageModel.rootURL

        XCTAssertEqual(root, iCloudStorageModel.unavailableContainerRoot)
        XCTAssertFalse(iCloudStorageModel.isRootAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNotEqual(root.standardizedFileURL,
                          LocalStorageModel.rootURL.standardizedFileURL,
                          "falling back to local Documents would list local albums a second time as iCloud Drive")
        XCTAssertTrue(iCloudStorageModel.enumerateAlbumsDirectory().isEmpty)
    }

    /// An `.icloud` album reached some other way (a stored plan, a stale current
    /// album) must fail its writes, not trap and not write somewhere local.
    func testICloudAlbumWithoutAContainerFailsToInitializeInsteadOfTrapping() throws {
        simulateSignedInAccountWithoutContainer()
        let key = PrivateKey(name: "key", keyBytes: Array(repeating: 0x5A, count: 32), creationDate: Date())
        let album = Album(name: "no-container-\(UUID().uuidString)", storageOption: .icloud,
                          creationDate: Date(), key: key)
        let model = iCloudStorageModel(album: album)

        XCTAssertTrue(model.baseURL.path.hasPrefix(iCloudStorageModel.unavailableContainerRoot.path))
        XCTAssertThrowsError(try model.initializeDirectories())
    }

    func testContainerLookupRunsOnceWhileSignedIn() {
        var lookups = 0
        let container = FileManager.default.temporaryDirectory
        iCloudStorageModel.containerSource = .init(hasIdentityToken: { true },
                                                   containerURL: { lookups += 1; return container })

        _ = iCloudStorageModel.rootURL
        _ = iCloudStorageModel.rootURL
        _ = iCloudStorageModel.isRootAvailable

        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(iCloudStorageModel.rootURL, container.appendingPathComponent("Documents"))
    }

    func testSigningOutDropsTheCachedLookup() {
        var lookups = 0
        var signedIn = true
        iCloudStorageModel.containerSource = .init(hasIdentityToken: { signedIn },
                                                   containerURL: { lookups += 1; return nil })

        _ = iCloudStorageModel.rootURL
        signedIn = false
        _ = iCloudStorageModel.rootURL
        signedIn = true
        _ = iCloudStorageModel.rootURL

        XCTAssertEqual(lookups, 2)
    }
}
