//
//  EraserUtilsTests.swift
//  EncameraCoreTests
//
//  Covers the erase contracts: the `.allData` wipe must invoke CloudKit deletion,
//  run EVERY local step even when the cloud delete fails (asserted through the
//  recording seam, not inferred from "did not throw"), gate the "iCloud data may
//  remain" warning on plausible cloud usage, persist the pending-wipe marker,
//  report every step running-then-terminal, and let a step's verification —
//  never its erase call — decide the outcome. `.reset` must run exactly the
//  reset tier: keys, settings and cleartext, never CloudKit or the encrypted
//  media. Every seam is a mock, so no real defaults, keychain, or filesystem are
//  wiped in the test process, except the migration and iCloud Drive steps the
//  linked-folder tests run for real against a scratch iCloud Drive root.
//

import XCTest
@testable import EncameraCore

final class EraserUtilsTests: XCTestCase {

    private final class MockCloudDataEraser: CloudDataErasing {
        var error: Error?
        var subscriptionError: Error?
        var mayHaveData = true
        /// What a re-read reports after the delete; a server that committed the
        /// delete despite a client-side error reports nothing.
        var zonesAfterDelete: [String] = []
        var subscriptionsAfterDelete: [String] = []
        var readError: Error?
        private(set) var callCount = 0
        private(set) var subscriptionDeleteCount = 0
        /// Runs as the zone delete starts.
        var onDelete: (() -> Void)?

        func deleteAllCloudData() async throws {
            callCount += 1
            onDelete?()
            if let error { throw error }
        }
        func deleteAllSubscriptions() async throws {
            subscriptionDeleteCount += 1
            if let subscriptionError { throw subscriptionError }
        }
        func remainingZoneNames() async throws -> [String] {
            if let readError { throw readError }
            return zonesAfterDelete
        }
        func remainingSubscriptionIDs() async throws -> [String] {
            if let readError { throw readError }
            return subscriptionsAfterDelete
        }
        func mayHaveCloudKitData() async -> Bool { mayHaveData }
    }

    private class RecordingLocalEraser: LocalDataErasing, @unchecked Sendable {
        var steps: [String] = []
        func shutdownCloudKitSync() async { steps.append("shutdownCloudKitSync") }
        func eraseMigrationState() async { steps.append("migrationState") }
        func eraseActiveBackendMedia() async { steps.append("activeBackendMedia") }
        func eraseAllLocalMediaFiles() { steps.append("allLocalMediaFiles") }
        func eraseICloudDriveMedia() async { steps.append("iCloudDriveMedia") }
        func eraseMediaIndexes() { steps.append("mediaIndexes") }
        func eraseBlobCache() async { steps.append("blobCache") }
        func eraseThumbnails() { steps.append("thumbnails") }
        func eraseTempDirectories() { steps.append("tempDirectories") }
        func eraseSharedContainerImports() async { steps.append("sharedContainerImports") }
        func eraseResidualContainerFiles() { steps.append("residualContainerFiles") }
        func eraseKeychain() { steps.append("keychain") }
        func eraseUserDefaults() { steps.append("userDefaults") }
        func recordPendingCloudWipe() { steps.append("pendingCloudWipe") }
    }

    /// Answers every verification with a scripted verdict, so a test can make one
    /// step "dirty" and watch what the runner does about it.
    private class ScriptedVerifier: LocalDataVerifying {
        var failing: [String: ErasureVerdict] = [:]
        private(set) var verified: [String] = []

        private func verdict(_ id: String) -> ErasureVerdict {
            verified.append(id)
            return failing[id] ?? .pass("\(id) clear")
        }
        func verifyCloudKitSyncShutdown() async -> ErasureVerdict { verdict("sync.shutdown") }
        func verifyMigrationState() async -> ErasureVerdict { verdict("migration.state") }
        func verifyActiveBackendMedia() async -> ErasureVerdict { verdict("media.activeBackend") }
        func verifyLocalMediaFiles() -> ErasureVerdict { verdict("media.localAlbums") }
        func verifyICloudDriveMedia() -> ErasureVerdict { verdict("media.iCloudDrive") }
        func verifyMediaIndexes() -> ErasureVerdict { verdict("media.indexes") }
        func verifyBlobCache() -> ErasureVerdict { verdict("media.blobCache") }
        func verifyThumbnails() -> ErasureVerdict { verdict("media.thumbnails") }
        func verifyTempDirectories() -> ErasureVerdict { verdict("media.temp") }
        func verifySharedContainerImports() -> ErasureVerdict { verdict("media.sharedImports") }
        func verifyResidualContainerFiles() -> ErasureVerdict { verdict("sweep.residual") }
        func verifyKeychain() -> ErasureVerdict { verdict("keys.keychain") }
        func verifyUserDefaults() -> ErasureVerdict { verdict("settings.defaults") }
        private(set) var deviceCleanScopes: [ErasureScope] = []
        func verifyDeviceClean(scope: ErasureScope) async -> ErasureVerdict {
            deviceCleanScopes.append(scope)
            return verdict("final.verify")
        }
    }

    private static let allDataSteps = [
        "migrationState", "shutdownCloudKitSync", "iCloudDriveMedia", "activeBackendMedia", "allLocalMediaFiles", "mediaIndexes",
        "blobCache", "thumbnails", "tempDirectories", "sharedContainerImports",
        "residualContainerFiles", "keychain", "userDefaults"
    ]

    private func makeUtils(scope: ErasureScope,
                           cloud: CloudDataErasing,
                           local: LocalDataErasing,
                           verifier: LocalDataVerifying = ScriptedVerifier(),
                           appLayerSteps: [ErasureStep] = [],
                           cancelPendingBackgroundSlices: @escaping @Sendable () -> Void = {}) -> EraserUtils {
        EraserUtils(keyManager: DemoKeyManager(),
                    fileAccess: InteractableMediaFileAccess(),
                    erasureScope: scope,
                    cloudKitEraser: cloud,
                    localEraser: local,
                    localVerifier: verifier,
                    appLayerSteps: appLayerSteps,
                    cancelPendingBackgroundSlices: cancelPendingBackgroundSlices)
    }

    /// Collects progress reports on the calling task, in order.
    private final class ProgressLog: @unchecked Sendable {
        private(set) var reports: [ErasureStepReport] = []
        func record(_ report: ErasureStepReport) { reports.append(report) }
    }

    // MARK: - Sequence

    func testEraseAllDataDeletesCloudKitDataAndRunsEveryLocalStep() async throws {
        let cloud = MockCloudDataEraser()
        let local = RecordingLocalEraser()

        let result = try await makeUtils(scope: .allData, cloud: cloud, local: local).erase()

        XCTAssertEqual(cloud.callCount, 1)
        XCTAssertEqual(cloud.subscriptionDeleteCount, 1, "the zone subscription is a record of its own")
        XCTAssertFalse(result.cloudKitDeletionFailed)
        XCTAssertEqual(local.steps, Self.allDataSteps,
                       "every local step runs, in order, with no pending-wipe marker on success")
    }

    func testEraseAllDataWipesTheDeviceBeforeReachingForICloud() async throws {
        let cloud = MockCloudDataEraser()
        let local = RecordingLocalEraser()
        var stepsBeforeCloudDelete: [String] = []
        cloud.onDelete = { stepsBeforeCloudDelete = local.steps }
        let appStep = ErasureStep(descriptor: .init(id: "app.test", title: "App state", section: .app),
                                  erase: { [local] in local.steps.append("appLayer") },
                                  verify: { .pass() })

        let utils = makeUtils(scope: .allData, cloud: cloud, local: local, appLayerSteps: [appStep])
        _ = try await utils.erase()

        XCTAssertEqual(stepsBeforeCloudDelete,
                       ["migrationState", "shutdownCloudKitSync", "iCloudDriveMedia", "activeBackendMedia", "allLocalMediaFiles",
                        "mediaIndexes", "blobCache", "thumbnails", "tempDirectories", "sharedContainerImports", "appLayer"],
                       "everything on the device goes before the zone delete, which waits on the network; the residual sweep, keychain and defaults follow it")
        let ids = utils.stepDescriptors.map(\.id)
        XCTAssertEqual(ids.firstIndex(of: "cloud.zones"), ids.firstIndex(of: "app.test").map { $0 + 1 },
                       "the checklist lists the steps in the order they run")
    }

    func testEraseAllDataCloudFailureStillRunsEveryLocalStepAndPersistsMarker() async throws {
        let cloud = MockCloudDataEraser()
        cloud.error = NSError(domain: "test", code: 1)
        cloud.readError = NSError(domain: "test", code: 2)
        let local = RecordingLocalEraser()

        let result = try await makeUtils(scope: .allData, cloud: cloud, local: local).erase()

        XCTAssertEqual(cloud.callCount, 1)
        XCTAssertTrue(result.cloudKitDeletionFailed)
        XCTAssertEqual(local.steps, Self.allDataSteps + ["pendingCloudWipe"],
                       "a cloud failure must not skip any local step, and the owed cloud wipe is persisted AFTER the defaults wipe")
    }

    func testEraseAllDataCloudFailureWithoutCloudUsageArmsNoRetryMarker() async throws {
        let cloud = MockCloudDataEraser()
        cloud.error = NSError(domain: "test", code: 1)
        cloud.mayHaveData = false
        let local = RecordingLocalEraser()
        let log = ProgressLog()

        let report = await makeUtils(scope: .allData, cloud: cloud, local: local)
            .erase(progress: { log.record($0) })

        XCTAssertFalse(report.cloudKitDeletionFailed,
                       "no plausible cloud data means no false-positive warning")
        XCTAssertEqual(report.report(for: "cloud.zones")?.outcome, .skipped,
                       "a device with no account has nothing in iCloud to fail on")
        XCTAssertEqual(local.steps, Self.allDataSteps,
                       "a device that cannot have CloudKit data owes no cloud wipe, so a later retry cannot delete data made after the erase")
    }

    private static let resetSteps = [
        "migrationState", "shutdownCloudKitSync", "thumbnails", "tempDirectories",
        "sharedContainerImports", "keychain", "userDefaults"
    ]

    func testResetRunsExactlyTheResetTier() async throws {
        let cloud = MockCloudDataEraser()
        let local = RecordingLocalEraser()
        let verifier = ScriptedVerifier()
        let log = ProgressLog()
        let utils = makeUtils(scope: .reset, cloud: cloud, local: local, verifier: verifier)

        let report = await utils.erase(progress: { log.record($0) })

        XCTAssertEqual(cloud.callCount, 0, "a pre-auth reset never deletes the CloudKit zone")
        XCTAssertEqual(cloud.subscriptionDeleteCount, 0)
        XCTAssertFalse(report.cloudKitDeletionFailed)
        XCTAssertEqual(local.steps, Self.resetSteps,
                       "the reset keeps the encrypted media, its indexes, the blob cache and upload queue, and skips the residual sweep that would take them")
        let expectedIDs = ["migration.state", "sync.shutdown", "media.thumbnails", "media.temp",
                           "media.sharedImports", "keys.keychain", "settings.defaults", "final.verify"]
        XCTAssertEqual(utils.stepDescriptors.map(\.id), expectedIDs)
        XCTAssertEqual(report.steps.map(\.id), expectedIDs)
        XCTAssertEqual(log.reports.filter { $0.outcome == .running }.map(\.id), expectedIDs)
        XCTAssertEqual(verifier.deviceCleanScopes, [.reset], "the final check verifies only what the reset promised")
        XCTAssertEqual(report.scope, .reset)
    }

    func testResetCatalogHoldsNoCiphertextStep() {
        let ciphertextIDs: Set<String> = ["cloud.zones", "cloud.subscriptions", "media.activeBackend",
                                          "media.localAlbums", "media.iCloudDrive", "media.indexes",
                                          "media.blobCache", "sweep.residual"]
        XCTAssertEqual(Set(ErasureStepDescriptor.allDataCatalog.filter { $0.tier == .ciphertext }.map(\.id)), ciphertextIDs)
        XCTAssertTrue(ErasureStepDescriptor.catalog(for: .reset).allSatisfy { $0.tier == .reset })
        XCTAssertEqual(ErasureStepDescriptor.catalog(for: .allData), ErasureStepDescriptor.allDataCatalog)
    }

    /// A marker left by an earlier failed erase is still owed: neither scope may
    /// write over it or drop it. The real defaults wipe keeps it
    /// (`UserDefaultsTombstoneTests`); here neither scope records a new one.
    func testResetNeverRecordsAPendingCloudWipe() async {
        let cloud = MockCloudDataEraser()
        cloud.error = NSError(domain: "test", code: 1)
        let local = RecordingLocalEraser()

        _ = await makeUtils(scope: .reset, cloud: cloud, local: local).erase(progress: { _ in })

        XCTAssertFalse(local.steps.contains("pendingCloudWipe"))
    }

    func testResetAppLayerStepsRunBeforeTheKeychain() async {
        let local = RecordingLocalEraser()
        let order = ProgressLog()
        let step = ErasureStep(
            descriptor: .init(id: "app.purchases", title: "Sign out of purchases", section: .app),
            erase: { order.record(.running("app.purchases:erase:\(local.steps.count)")) },
            verify: { .pass("signed out") }
        )
        let utils = makeUtils(scope: .reset, cloud: MockCloudDataEraser(), local: local, appLayerSteps: [step])

        _ = await utils.erase(progress: { _ in })

        XCTAssertEqual(order.reports.first?.id, "app.purchases:erase:\(Self.resetSteps.firstIndex(of: "keychain")!)")
        XCTAssertTrue(utils.stepDescriptors.contains { $0.id == "app.purchases" })
    }

    /// The Share Extension hands over DECRYPTED media, so the App Group import
    /// directory is cleartext on disk. Both scopes sweep it.
    func testBothScopesClearTheCleartextSharedContainerImports() async throws {
        for scope in [ErasureScope.allData, .reset] {
            let local = RecordingLocalEraser()
            _ = try await makeUtils(scope: scope, cloud: MockCloudDataEraser(), local: local).erase()
            XCTAssertTrue(local.steps.contains("sharedContainerImports"),
                          "\(scope) left the Share Extension's cleartext imports on disk")
        }
    }

    // MARK: - Progress reporting

    func testEveryCatalogStepIsReportedRunningThenTerminalInOrder() async {
        let utils = makeUtils(scope: .allData, cloud: MockCloudDataEraser(), local: RecordingLocalEraser())
        let log = ProgressLog()

        let report = await utils.erase(progress: { log.record($0) })

        let expectedIDs = utils.stepDescriptors.map(\.id)
        XCTAssertEqual(expectedIDs, ErasureStepDescriptor.allDataCatalog.map(\.id))
        XCTAssertEqual(log.reports.filter { $0.outcome == .running }.map(\.id), expectedIDs,
                       "each step announces itself before it runs")
        XCTAssertEqual(log.reports.filter { $0.outcome != .running }.map(\.id), expectedIDs,
                       "each step lands exactly one terminal report, in run order")
        XCTAssertEqual(report.steps.map(\.id), expectedIDs)
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.markerText, "complete:ok=\(expectedIDs.count)/\(expectedIDs.count):fail=")
    }

    func testAFailedVerificationMarksOnlyThatStepAndTheRunContinues() async {
        let verifier = ScriptedVerifier()
        verifier.failing["keys.keychain"] = .residue("keychain items", names: ["GenericPassword|encamera"], hint: .keychain)
        let local = RecordingLocalEraser()
        let utils = makeUtils(scope: .allData, cloud: MockCloudDataEraser(), local: local, verifier: verifier)

        let report = await utils.erase(progress: { _ in })

        XCTAssertEqual(report.failures.map(\.id), ["keys.keychain"])
        XCTAssertEqual(report.report(for: "keys.keychain")?.hint, .keychain)
        XCTAssertEqual(report.report(for: "settings.defaults")?.outcome, .pass, "later steps still run")
        XCTAssertEqual(report.report(for: "final.verify")?.outcome, .pass)
        XCTAssertEqual(local.steps, Self.allDataSteps, "a failed verification never skips an erase")
        let total = utils.stepDescriptors.count
        XCTAssertEqual(report.markerText, "complete:ok=\(total - 1)/\(total):fail=keys.keychain")
    }

    /// The outcome belongs to the verification, not to the erase call: an erase
    /// that throws but leaves nothing behind is a pass, and one that returns
    /// quietly over surviving data is a failure.
    func testVerificationDecidesTheOutcomeNotTheEraseCall() async {
        let cloud = MockCloudDataEraser()
        cloud.error = NSError(domain: "test", code: 1)
        cloud.zonesAfterDelete = []
        let report = await makeUtils(scope: .allData, cloud: cloud, local: RecordingLocalEraser())
            .erase(progress: { _ in })

        let zones = report.report(for: "cloud.zones")
        XCTAssertEqual(zones?.outcome, .pass, "the server committed the delete despite the client error")
        XCTAssertTrue(zones?.detail.contains("erase error") == true, "the error is kept as evidence")

        let stubborn = MockCloudDataEraser()
        stubborn.zonesAfterDelete = ["EncameraZone"]
        let dirty = await makeUtils(scope: .allData, cloud: stubborn, local: RecordingLocalEraser())
            .erase(progress: { _ in })
        XCTAssertEqual(dirty.report(for: "cloud.zones")?.outcome, .fail, "a zone that is still there is a failure however the delete returned")
        XCTAssertEqual(dirty.report(for: "cloud.zones")?.hint, .cloudUnreachable)
    }

    func testUnreachableCloudReadIsAFailureWithTheRetryHint() async {
        let cloud = MockCloudDataEraser()
        cloud.error = NSError(domain: "test", code: 1)
        cloud.readError = NSError(domain: "test", code: 2)
        let report = await makeUtils(scope: .allData, cloud: cloud, local: RecordingLocalEraser())
            .erase(progress: { _ in })

        XCTAssertEqual(report.report(for: "cloud.zones")?.outcome, .fail)
        XCTAssertEqual(report.report(for: "cloud.zones")?.hint, .cloudUnreachable)
        XCTAssertTrue(report.cloudKitDeletionFailed)
    }

    func testSurvivingSubscriptionFailsTheSubscriptionStep() async {
        let cloud = MockCloudDataEraser()
        cloud.subscriptionsAfterDelete = ["EncameraZoneSubscription"]
        let report = await makeUtils(scope: .allData, cloud: cloud, local: RecordingLocalEraser())
            .erase(progress: { _ in })

        XCTAssertEqual(report.report(for: "cloud.subscriptions")?.outcome, .fail)
        XCTAssertEqual(report.report(for: "cloud.zones")?.outcome, .pass)
    }

    // MARK: - App-layer steps

    func testAppLayerStepsRunAfterMediaAndBeforeTheResidualSweepKeychainAndDefaults() async {
        let local = RecordingLocalEraser()
        let order = ProgressLog()
        let step = ErasureStep(
            descriptor: .init(id: "app.purchases", title: "Sign out of purchases", section: .app),
            erase: { order.record(.running("app.purchases:erase:\(local.steps.count)")) },
            verify: { .pass("signed out") }
        )
        let utils = makeUtils(scope: .allData, cloud: MockCloudDataEraser(), local: local, appLayerSteps: [step])

        let report = await utils.erase(progress: { _ in })

        let mediaSteps = Self.allDataSteps.firstIndex(of: "residualContainerFiles")!
        XCTAssertEqual(order.reports.first?.id, "app.purchases:erase:\(mediaSteps)",
                       "app-layer steps run before the residual sweep, keychain and defaults wipes so what they write is wiped too")
        XCTAssertEqual(report.report(for: "app.purchases")?.outcome, .pass)

        let ids = utils.stepDescriptors.map(\.id)
        XCTAssertLessThan(ids.firstIndex(of: "media.sharedImports")!, ids.firstIndex(of: "app.purchases")!)
        XCTAssertLessThan(ids.firstIndex(of: "app.purchases")!, ids.firstIndex(of: "sweep.residual")!)
        XCTAssertEqual(utils.stepDescriptors.first { $0.id == "app.purchases" }?.section, .app)
    }

    func testAThrowingAppLayerStepIsJudgedByItsVerification() async {
        let throwing = ErasureStep(
            descriptor: .init(id: "app.analytics", title: "Delete analytics", section: .app),
            erase: { throw NSError(domain: "sdk", code: 9) },
            verify: { .fail("event store still present", hint: .retry) }
        )
        let report = await makeUtils(scope: .allData, cloud: MockCloudDataEraser(), local: RecordingLocalEraser(),
                                     appLayerSteps: [throwing])
            .erase(progress: { _ in })

        XCTAssertEqual(report.report(for: "app.analytics")?.outcome, .fail)
        XCTAssertEqual(report.report(for: "app.analytics")?.hint, .retry)
        XCTAssertEqual(report.report(for: "final.verify")?.outcome, .pass, "the run carried on")
    }

    // MARK: - Linked iCloud Drive folders and migration state

    /// Runs the migration and iCloud Drive steps for real and records the rest.
    private final class PartlyRealLocalEraser: RecordingLocalEraser, @unchecked Sendable {
        private let real = DefaultLocalDataEraser(keyManager: DemoKeyManager(), fileAccess: InteractableMediaFileAccess())

        override func eraseMigrationState() async {
            steps.append("migrationState")
            await real.eraseMigrationState()
        }

        override func eraseICloudDriveMedia() async {
            steps.append("iCloudDriveMedia")
            await real.eraseICloudDriveMedia()
        }
    }

    /// Verifies the migration and iCloud Drive steps for real and passes the rest.
    private final class PartlyRealVerifier: ScriptedVerifier {
        private let real = DefaultLocalDataVerifier(keyManager: DemoKeyManager(), fileAccess: InteractableMediaFileAccess())

        override func verifyMigrationState() async -> ErasureVerdict { await real.verifyMigrationState() }
        override func verifyICloudDriveMedia() -> ErasureVerdict { real.verifyICloudDriveMedia() }
    }

    private struct LinkedFolders {
        /// Linked by a local marker; its own marker file is evicted.
        let byLocalMarker: URL
        let localMarkerAlbumID: String
        /// Holds a marker file; no local marker links it.
        let byMarkerFile: URL
        let markerFileAlbumID: String
    }

    private var iCloudDriveRoot: URL?
    private var writtenLocalMarkerIDs: [String] = []

    override func setUp() {
        super.setUp()
        UserDefaultUtils.current = UserDefaultUtils()
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ICloudDriveBlobMigration._testClearEraseHalt()
            CloudKitMigrationManager._testClearAbortAll()
            BlobMigrationKeyCache.shared.clear()
        }
        for albumID in writtenLocalMarkerIDs {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
            MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: albumID)
        }
        writtenLocalMarkerIDs = []
        try? MigrationPlanStore.clearAllPlans()
        DeletedCloudKitAlbums().removeAll()
        if let iCloudDriveRoot {
            iCloudStorageModel.testContainerRootOverride = nil
            try? FileManager.default.removeItem(at: iCloudDriveRoot)
        }
        iCloudDriveRoot = nil
        UserDefaultUtils.current = UserDefaultUtils()
        super.tearDown()
    }

    /// A scratch iCloud Drive root holding two linked folders in the legacy
    /// layout, where only a linked-folder lookup finds them, each with a media
    /// file and an iCloud Drive migration plan.
    private func makeLinkedFolders() throws -> LinkedFolders {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("erase-linked-\(UUID().uuidString)", isDirectory: true)
        iCloudDriveRoot = root
        iCloudStorageModel.testContainerRootOverride = root

        let byLocalMarker = root.appendingPathComponent("Album_\(UUID().uuidString)", isDirectory: true)
        let byMarkerFile = root.appendingPathComponent("Album_\(UUID().uuidString)", isDirectory: true)
        for folder in [byLocalMarker, byMarkerFile] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("ciphertext".utf8).write(to: folder.appendingPathComponent("\(UUID().uuidString).encimage"))
        }

        let localMarkerAlbumID = UUID().uuidString
        FileManager.default.createFile(
            atPath: byLocalMarker.appendingPathComponent(ICloudDriveAlbumMarkerFile.placeholderFileName).path,
            contents: Data())
        try CloudKitAlbumMarker(encName: "enc", createdAt: Date(), iCloudDriveFolderPath: byLocalMarker.lastPathComponent)
            .write(albumID: localMarkerAlbumID)
        writtenLocalMarkerIDs.append(localMarkerAlbumID)

        let markerFileAlbumID = UUID().uuidString
        try ICloudDriveAlbumMarkerFile(albumID: markerFileAlbumID).write(toAlbumDirectory: byMarkerFile)
        writtenLocalMarkerIDs.append(markerFileAlbumID)

        for albumID in [localMarkerAlbumID, markerFileAlbumID] {
            try writePlaceholderPlan(at: MigrationPlanStore.iCloudDriveMigrationPlanURL(cloudKitAlbumID: albumID))
        }
        return LinkedFolders(byLocalMarker: byLocalMarker, localMarkerAlbumID: localMarkerAlbumID,
                             byMarkerFile: byMarkerFile, markerFileAlbumID: markerFileAlbumID)
    }

    private func writePlaceholderPlan(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plan".utf8).write(to: url)
    }

    @MainActor
    func testAccountWideEraseRemovesLinkedICloudDriveFolders() async throws {
        let folders = try makeLinkedFolders()
        DeletedCloudKitAlbums().insert(UUID().uuidString)
        XCTAssertEqual(DefaultLocalDataVerifier.linkedICloudDriveFolders().count, 2,
                       "precondition: the verifier finds both linked folders")

        let local = PartlyRealLocalEraser()
        let report = await makeUtils(scope: .allData, cloud: MockCloudDataEraser(), local: local,
                                     verifier: PartlyRealVerifier())
            .erase(progress: { _ in })

        XCTAssertEqual(local.steps, Self.allDataSteps)
        for folder in [folders.byLocalMarker, folders.byMarkerFile] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path),
                           "\(folder.lastPathComponent) holds the only copy of items not yet in CloudKit and goes with the erase")
        }
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: folders.localMarkerAlbumID)?.iCloudDriveFolderPath,
                     "no local marker links a folder after the erase")
        for albumID in [folders.localMarkerAlbumID, folders.markerFileAlbumID] {
            XCTAssertFalse(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: albumID), "no plan into \(albumID) remains")
        }
        XCTAssertTrue(DeletedCloudKitAlbums().all().isEmpty,
                      "with every linked folder gone, no deleted album is left to hide a new folder")
        XCTAssertEqual(report.report(for: "media.iCloudDrive")?.outcome, .pass)
        XCTAssertEqual(report.report(for: "migration.state")?.outcome, .pass)
        XCTAssertTrue(DefaultLocalDataVerifier.linkedICloudDriveFolders().isEmpty)
    }

    /// The verifier names a linked folder that survived, so an erase that missed
    /// one fails its step.
    @MainActor
    func testICloudDriveVerificationFailsOnASurvivingLinkedFolder() throws {
        let folders = try makeLinkedFolders()
        let verifier = DefaultLocalDataVerifier(keyManager: DemoKeyManager(), fileAccess: InteractableMediaFileAccess())

        let verdict = verifier.verifyICloudDriveMedia()

        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.detail.contains(folders.byLocalMarker.lastPathComponent), verdict.detail)
        XCTAssertTrue(verdict.detail.contains(folders.byMarkerFile.lastPathComponent), verdict.detail)
        let files = DefaultErasureVerifier(keyManager: DemoKeyManager()).survivingFilesForTesting(scope: .allData, containerPathLimit: 0)
        XCTAssertTrue(files.contains("linkedICloudDriveFolder:\(folders.byMarkerFile.lastPathComponent)"), "\(files)")
        XCTAssertFalse(DefaultErasureVerifier(keyManager: DemoKeyManager()).survivingFilesForTesting(scope: .reset)
            .contains { $0.hasPrefix("linkedICloudDriveFolder:") },
                       "a reset keeps the folders, so they are not its residue")
    }

    @MainActor
    func testLocalResetLeavesLinkedFoldersAlone() async throws {
        let folders = try makeLinkedFolders()
        let contentsBefore = try [folders.byLocalMarker, folders.byMarkerFile].map {
            try FileManager.default.contentsOfDirectory(atPath: $0.path).sorted()
        }

        let local = PartlyRealLocalEraser()
        _ = await makeUtils(scope: .reset, cloud: MockCloudDataEraser(), local: local, verifier: PartlyRealVerifier())
            .erase(progress: { _ in })

        XCTAssertEqual(local.steps, Self.resetSteps)
        let contentsAfter = try [folders.byLocalMarker, folders.byMarkerFile].map {
            try FileManager.default.contentsOfDirectory(atPath: $0.path).sorted()
        }
        XCTAssertEqual(contentsAfter, contentsBefore, "a reset keeps the encrypted media, in the linked folders too")
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: folders.localMarkerAlbumID)?.iCloudDriveFolderPath,
                       folders.byLocalMarker.lastPathComponent, "the album still links its folder")
    }

    @MainActor
    func testEraseRemovesMigrationPlansAndCancelsSlices() async throws {
        let key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let albumManager = AlbumManager(keyManager: DemoKeyManager(keys: [key]), syncedDataStore: nil)
        for scope in [ErasureScope.allData, .reset] {
            ICloudDriveBlobMigration._testClearEraseHalt()
            let localAlbum = Album(name: "move-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: key)
            let localPlan = MigrationPlanStore.planURL(for: localAlbum)
            let iCloudDrivePlan = MigrationPlanStore.iCloudDriveMigrationPlanURL(cloudKitAlbumID: UUID().uuidString)
            try writePlaceholderPlan(at: localPlan)
            try writePlaceholderPlan(at: iCloudDrivePlan)
            BlobMigrationKeyCache.shared.refreshKeysFromKeychain(using: albumManager)
            XCTAssertEqual(BlobMigrationKeyCache.shared.storedKeys.count, 1, "precondition: keys are held in memory")

            let local = PartlyRealLocalEraser()
            let report = await makeUtils(scope: scope, cloud: MockCloudDataEraser(), local: local,
                                         verifier: PartlyRealVerifier(),
                                         cancelPendingBackgroundSlices: { [local] in local.steps.append("cancelSlices") })
                .erase(progress: { _ in })

            XCTAssertEqual(local.steps.first, "cancelSlices", "\(scope): pending slices are cancelled before anything is erased")
            XCTAssertEqual(local.steps.filter { $0 == "cancelSlices" }.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: localPlan.path), "\(scope): the local move's plan goes")
            XCTAssertFalse(FileManager.default.fileExists(atPath: iCloudDrivePlan.path), "\(scope): the iCloud Drive album's plan goes")
            XCTAssertEqual(report.report(for: "migration.state")?.outcome, .pass)
            XCTAssertTrue(BlobMigrationKeyCache.shared.storedKeys.isEmpty, "\(scope): the keys held for locked slices are cleared")
            XCTAssertTrue(ICloudDriveBlobMigration.isHaltedForErase)

            let loop = ICloudDriveBlobMigration(albumManager: albumManager,
                                                conditions: .init(isUnlocked: { true }, hasNetwork: { true }, isOnUnmeteredNetwork: { true },
                                                                  hasICloudDrive: { true }))
            let slice = await loop.runBackgroundTaskPasses()
            XCTAssertTrue(slice.outcomes.isEmpty)
            XCTAssertTrue(BlobMigrationKeyCache.shared.storedKeys.isEmpty,
                          "\(scope): a slice handler run after the erase reads no keys")
            let pass = await loop.runMigrationPass(albumID: UUID().uuidString, folder: FileManager.default.temporaryDirectory)
            XCTAssertEqual(pass, .stopped(.erased, .init()), "\(scope): no pass starts after the erase")
            XCTAssertFalse(loop.startMigrationPass(albumID: UUID().uuidString, folder: FileManager.default.temporaryDirectory),
                           "\(scope): nor does a pass the album step starts")
        }
    }
}
