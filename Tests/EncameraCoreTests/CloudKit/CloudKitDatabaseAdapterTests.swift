//
//  CloudKitDatabaseAdapterTests.swift
//  EncameraCoreTests
//
//  The adapter's error-surfacing contract: per-record failures of an
//  overall-successful CKModifyRecordsOperation must reach callers in the same
//  `.partialFailure` shape a failed operation produces — carrying EVERY failed
//  record — so `mapCKError` handles them deterministically
//  (Dictionary.first would leak an arbitrary raw error instead).
//

import XCTest
import CloudKit
@testable import EncameraCore

@MainActor
final class CloudKitDatabaseAdapterTests: XCTestCase {

    func testPerRecordSaveFailuresSurfaceAsPartialCarryingEveryRecord() {
        let failures: [CKRecord.ID: Error] = [
            CKRecord.ID(recordName: "r-quota"): CKErrorFactory.error(.quotaExceeded),
            CKRecord.ID(recordName: "r-conflict"): CKErrorFactory.error(.serverRecordChanged),
        ]

        let mapped = mapCKError(CKDatabaseAdapter.perRecordSaveFailureError(failures))

        guard case .partial(let failed) = mapped else {
            return XCTFail("expected .partial so the caller can unwrap deterministically, got \(mapped)")
        }
        XCTAssertEqual(Set(failed.keys), ["r-quota", "r-conflict"],
                       "every per-record failure is carried — never an arbitrary Dictionary.first pick")
    }

    /// A single record's failure is classified the same as the bare error, so a
    /// caller switching on `.conflict` recognises a wrapped one.
    func testSinglePerRecordSaveFailureMapsToItsUnderlyingError() {
        let failures: [CKRecord.ID: Error] = [
            CKRecord.ID(recordName: "r1"): CKErrorFactory.error(.serverRecordChanged),
        ]

        let mapped = mapCKError(CKDatabaseAdapter.perRecordSaveFailureError(failures))

        guard case .conflict = mapped else {
            return XCTFail("a single-record partial must map to its underlying error, got \(mapped)")
        }
        guard case .conflict = CloudKitMigrationManager.unwrapPartial(mapped) else {
            return XCTFail("unwrapping an already-unwrapped error leaves it as it is")
        }
    }

    /// Swift task cancellation has to reach the CKOperation. Without this, a
    /// cancelled blob download kept transferring in the background — the user's
    /// Cancel stopped nothing, it only stopped them watching.
    func testCancellingTheAwaitingTaskCancelsTheCloudKitOperation() async throws {
        let operation = CKFetchRecordsOperation(recordIDs: [CKRecord.ID(recordName: "m1")])
        let held = ContinuationBox()
        let started = expectation(description: "the operation was dispatched")

        let task = Task {
            try await CKDatabaseAdapter.runCancellable(operation) { continuation in
                held.store(continuation)
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 5)

        task.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(operation.isCancelled,
                      "Cancelling the awaiting task must cancel the CKOperation, not just abandon it")

        held.resume(throwing: CKErrorFactory.error(.operationCancelled))
        _ = try? await task.value
    }

    // MARK: - Asset snapshots

    /// The snapshot exists because a `CKAsset`'s staged file is only guaranteed
    /// valid inside the delivery block. That lifetime has to end somewhere: one
    /// copy per fetched chunk, twenty chunks a video, and nothing deleting them
    /// grew tmp by the size of every video ever played.
    func testAssetSnapshotsLandInTheSweptDirectory() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-source-\(UUID().uuidString).bin")
        try Data(repeating: 0x5A, count: 2_048).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let record = CKRecord(recordType: CloudKitSchema.EncMedia.recordType,
                              recordID: CloudKitTestFactory.recordID("snap-1"))
        record[CloudKitSchema.EncMedia.encBlob] = CKAsset(fileURL: source)

        CKDatabaseAdapter.snapshotAssets(of: record)

        let snapshot = try XCTUnwrap((record[CloudKitSchema.EncMedia.encBlob] as? CKAsset)?.fileURL)
        XCTAssertNotEqual(snapshot, source, "the record should point at the copy, not the staged file")
        XCTAssertEqual(snapshot.deletingLastPathComponent().standardizedFileURL,
                       CKDatabaseAdapter.assetSnapshotDirectory.standardizedFileURL,
                       "a snapshot loose in the tmp root cannot be swept in bulk, which is how they accumulated")

        CKDatabaseAdapter.discardSnapshot(at: snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path),
                       "the reader must be able to reclaim its own snapshot")
    }

    /// `discardSnapshot` is handed whatever URL a record carries, which for an
    /// un-snapshotted record is a file CloudKit still owns. Deleting that would
    /// be deleting the system's copy out from under it.
    func testDiscardSnapshotIgnoresPathsOutsideItsDirectory() throws {
        let outsider = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-snapshot-\(UUID().uuidString).bin")
        try Data(repeating: 0x11, count: 16).write(to: outsider)
        defer { try? FileManager.default.removeItem(at: outsider) }

        CKDatabaseAdapter.discardSnapshot(at: outsider)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsider.path),
                      "only files inside the snapshot directory may be deleted")
    }

    // MARK: - Network policy

    /// Every request the adapter sends under `.background` runs at utility QoS
    /// with cellular off, read from the operation handed to CloudKit.
    func testBackgroundPolicyDisallowsCellularAndUsesLowQoS() async throws {
        let capture = OperationCapture()
        let adapter = CKDatabaseAdapter(networkPolicy: { .background }, enqueue: capture.append)

        let operations = try await dispatchEveryRequest(through: adapter, capture: capture)

        XCTAssertEqual(operations.count, 5)
        for operation in operations {
            XCTAssertFalse(operation.configuration.allowsCellularAccess,
                           "\(type(of: operation)) must not use cellular under the background policy")
            XCTAssertEqual(operation.configuration.qualityOfService, .utility,
                           "\(type(of: operation)) must run below user-initiated under the background policy")
        }
        let save = try XCTUnwrap(operations.first as? CKModifyRecordsOperation)
        XCTAssertEqual(save.recordsToSave?.count, 1, "the first is the upload's save")
    }

    /// `.speedUp` raises requests to user-initiated QoS and keeps cellular off,
    /// and a policy switched mid-run applies to the next request.
    func testSpeedUpPolicyRaisesQoSAndKeepsCellularOff() async throws {
        let capture = OperationCapture()
        let policy = PolicyBox(.background)
        let adapter = CKDatabaseAdapter(networkPolicy: { policy.value }, enqueue: capture.append)

        let before = try await dispatch(through: adapter, capture: capture) { adapter in
            _ = try await adapter.save(records: [Self.record()], savePolicy: .ifServerRecordUnchanged,
                                       perRecordProgress: { _, _ in })
        }
        policy.value = .speedUp
        let operations = try await dispatchEveryRequest(through: adapter, capture: capture)

        XCTAssertEqual(before.configuration.qualityOfService, .utility, "precondition: background before the switch")
        for operation in operations {
            XCTAssertFalse(operation.configuration.allowsCellularAccess,
                           "\(type(of: operation)) must not use cellular under the speed-up policy")
            XCTAssertEqual(operation.configuration.qualityOfService, .userInitiated,
                           "\(type(of: operation)) runs user-initiated under the speed-up policy")
        }
    }

    /// An adapter without a policy, as every store outside the migration has,
    /// leaves CloudKit's default cellular access alone.
    func testAdapterWithoutPolicyLeavesDefaultCellularAccess() async throws {
        let capture = OperationCapture()
        let adapter = CKDatabaseAdapter(networkPolicy: nil, enqueue: capture.append)

        let operations = try await dispatchEveryRequest(through: adapter, capture: capture)

        XCTAssertEqual(operations.count, 5)
        for operation in operations {
            XCTAssertTrue(operation.configuration.allowsCellularAccess,
                          "\(type(of: operation)) keeps CloudKit's default cellular access without a policy")
        }
    }

    // MARK: - Migration stores

    /// `makeMigrationStore` builds its store under the blob migration's policy,
    /// which keeps cellular off whether it is `.background` or `.speedUp`.
    func testMakeMigrationStoreAppliesWiFiOnlyPolicy() async throws {
        let captured = PolicyClosureBox()
        await withUnboundStoreProvider(makePolicyStore: { policy in
            captured.closure = policy
            return InMemoryCloudKitMediaStore()
        }) {
            _ = CloudKitStoreProvider.makeMigrationStore("iCloudDriveAlbumMigration")
        }
        let policy = try XCTUnwrap(captured.closure, "an unbound provider builds the store with a policy")
        let savedPolicy = ICloudDriveBlobMigration.networkPolicy
        defer { ICloudDriveBlobMigration.networkPolicy = savedPolicy }

        for migrationPolicy in [CloudKitNetworkPolicy.background, .speedUp] {
            ICloudDriveBlobMigration.networkPolicy = migrationPolicy
            XCTAssertEqual(policy(), migrationPolicy, "the store reads the blob migration's policy per request")

            let capture = OperationCapture()
            let adapter = CKDatabaseAdapter(networkPolicy: policy, enqueue: capture.append)
            for operation in try await dispatchEveryRequest(through: adapter, capture: capture) {
                XCTAssertFalse(operation.configuration.allowsCellularAccess,
                               "\(type(of: operation)) must not use cellular under \(migrationPolicy)")
            }
        }
    }

    /// The blob migration's default store reads `requestPolicy`, so its requests
    /// use cellular once the user allows it, while `makeMigrationStore` stays
    /// Wi-Fi only.
    func testBlobMigrationStoreFollowsCellularPreference() async throws {
        let suiteName = "CloudKitDatabaseAdapterTests-\(UUID().uuidString)"
        UserDefaultUtils.current = UserDefaultUtils(defaults: UserDefaults(suiteName: suiteName)!)
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaultUtils.current = UserDefaultUtils()
        }
        let blobPolicy = PolicyClosureBox()
        let migrationPolicy = PolicyClosureBox()
        await withUnboundStoreProvider(makePolicyStore: { policy in
            blobPolicy.closure = policy
            return InMemoryCloudKitMediaStore()
        }) {
            _ = ICloudDriveBlobMigration.makeDefaultStore()
        }
        await withUnboundStoreProvider(makePolicyStore: { policy in
            migrationPolicy.closure = policy
            return InMemoryCloudKitMediaStore()
        }) {
            _ = CloudKitStoreProvider.makeMigrationStore("iCloudDriveAlbumFolderWalk")
        }
        let blob = try XCTUnwrap(blobPolicy.closure)
        let other = try XCTUnwrap(migrationPolicy.closure)

        XCTAssertFalse(blob().allowsCellularAccess, "off until the user allows cellular")
        ICloudDriveBlobMigrationCellularPreference.isAllowed = true
        XCTAssertTrue(blob().allowsCellularAccess, "read per request, so the switch reaches a pass under way")
        XCTAssertFalse(other().allowsCellularAccess, "other migration stores stay Wi-Fi only")
    }

    /// A bound factory, such as the UI-test mock, is what a migration store is.
    func testBoundFactoryIsUsedAsIsForMigrationStore() {
        let bound = InMemoryCloudKitMediaStore()
        let savedFactory = CloudKitStoreProvider.makeStore
        let savedPolicyStore = CloudKitStoreProvider.makePolicyStore
        let wasBound = CloudKitStoreProvider.isMakeStoreBound
        defer {
            CloudKitStoreProvider.makeStore = savedFactory
            CloudKitStoreProvider.makePolicyStore = savedPolicyStore
            CloudKitStoreProvider.isMakeStoreBound = wasBound
        }
        let policyStoreCalls = CallCount()
        CloudKitStoreProvider.makePolicyStore = { _ in
            policyStoreCalls.increment()
            return InMemoryCloudKitMediaStore()
        }
        CloudKitStoreProvider.makeStore = { _ in bound }

        let store = CloudKitStoreProvider.makeMigrationStore("iCloudDriveBlobMigration")

        XCTAssertTrue(store as AnyObject === bound)
        XCTAssertEqual(policyStoreCalls.value, 0, "a bound factory is used without building a policy store")
    }

    private func withUnboundStoreProvider(
        makePolicyStore: @escaping @Sendable (@escaping @Sendable () -> CloudKitNetworkPolicy) -> CloudKitMediaStoring,
        _ body: () async throws -> Void
    ) async rethrows {
        let savedPolicyStore = CloudKitStoreProvider.makePolicyStore
        let wasBound = CloudKitStoreProvider.isMakeStoreBound
        defer {
            CloudKitStoreProvider.makePolicyStore = savedPolicyStore
            CloudKitStoreProvider.isMakeStoreBound = wasBound
        }
        CloudKitStoreProvider.isMakeStoreBound = false
        CloudKitStoreProvider.makePolicyStore = makePolicyStore
        try await body()
    }

    private static func record() -> CKRecord {
        CKRecord(recordType: CloudKitSchema.EncMedia.recordType, recordID: CKRecord.ID(recordName: "m1"))
    }

    /// Sends a save, a delete, a fetch, a query and a zone-changes fetch, each
    /// failed once it reaches CloudKit, and returns the operations in that order.
    private func dispatchEveryRequest(through adapter: CKDatabaseAdapter,
                                      capture: OperationCapture) async throws -> [CKDatabaseOperation] {
        let zoneID = CKRecordZone.ID(zoneName: "zone")
        let id = CKRecord.ID(recordName: "m1")
        return [
            try await dispatch(through: adapter, capture: capture) {
                _ = try await $0.save(records: [Self.record()], savePolicy: .ifServerRecordUnchanged,
                                      perRecordProgress: { _, _ in })
            },
            try await dispatch(through: adapter, capture: capture) { _ = try await $0.delete(recordIDs: [id]) },
            try await dispatch(through: adapter, capture: capture) {
                _ = try await $0.fetch(recordIDs: [id], desiredKeys: nil, perRecordProgress: { _, _ in })
            },
            try await dispatch(through: adapter, capture: capture) {
                _ = try await $0.query(recordType: CloudKitSchema.EncMedia.recordType,
                                       predicate: NSPredicate(value: true), zoneID: zoneID, desiredKeys: nil)
            },
            try await dispatch(through: adapter, capture: capture) {
                _ = try await $0.fetchZoneChanges(zoneID: zoneID, since: nil, desiredKeys: nil)
            },
        ]
    }

    /// Runs `request`, waits for its operation to reach CloudKit, then fails it
    /// through its result block so the request returns.
    private func dispatch(through adapter: CKDatabaseAdapter,
                          capture: OperationCapture,
                          _ request: @escaping @Sendable (CKDatabaseAdapter) async throws -> Void) async throws -> CKDatabaseOperation {
        let countBefore = capture.operations.count
        let task = Task { try await request(adapter) }
        let deadline = Date().addingTimeInterval(5)
        while capture.operations.count == countBefore, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let operation = try XCTUnwrap(capture.operations.last, "the request reached CloudKit")
        XCTAssertEqual(capture.operations.count, countBefore + 1, "one operation per request")
        let error = CKErrorFactory.error(.networkUnavailable)
        switch operation {
        case let modify as CKModifyRecordsOperation: modify.modifyRecordsResultBlock?(.failure(error))
        case let fetch as CKFetchRecordsOperation: fetch.fetchRecordsResultBlock?(.failure(error))
        case let query as CKQueryOperation: query.queryResultBlock?(.failure(error))
        case let changes as CKFetchRecordZoneChangesOperation: changes.fetchRecordZoneChangesResultBlock?(.failure(error))
        default: XCTFail("unexpected operation \(operation)")
        }
        _ = try? await task.value
        return operation
    }
}

/// The operations an adapter handed to CloudKit, in order.
private final class OperationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CKDatabaseOperation] = []

    var operations: [CKDatabaseOperation] { lock.withLock { stored } }
    func append(_ operation: CKDatabaseOperation) { lock.withLock { stored.append(operation) } }
}

private final class PolicyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CloudKitNetworkPolicy
    init(_ value: CloudKitNetworkPolicy) { stored = value }
    var value: CloudKitNetworkPolicy {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Holds a continuation the test resumes by hand, standing in for CloudKit's
/// completion block.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[CKRecord.ID: CKRecord], Error>?

    func store(_ continuation: CheckedContinuation<[CKRecord.ID: CKRecord], Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func resume(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}

private final class PolicyClosureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable () -> CloudKitNetworkPolicy)?
    var closure: (@Sendable () -> CloudKitNetworkPolicy)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}
