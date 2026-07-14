//
//  CloudKitDatabaseAdapter.swift
//  EncameraCore
//
//  The narrow database-operation surface `CloudKitMediaStore` talks to, plus the
//  production `CKDatabase`-backed implementation. Tests substitute an in-memory
//  fake (`MockCloudKitDatabase`) so CI never hits the network or needs an account.
//

import Foundation
import CloudKit

/// Result of one zone-changes delta fetch.
public struct ZoneChangesResult {
    public let changed: [CKRecord]
    public let deletedRecordNames: [String]
    public let token: CKServerChangeToken?
    public let moreComing: Bool

    public init(changed: [CKRecord],
                deletedRecordNames: [String],
                token: CKServerChangeToken?,
                moreComing: Bool) {
        self.changed = changed
        self.deletedRecordNames = deletedRecordNames
        self.token = token
        self.moreComing = moreComing
    }
}

/// Everything the store needs from a CloudKit database, expressed at a level that
/// is trivial to fake. The store stays free of `CKOperation` wiring.
public protocol CloudKitDatabaseAdapter: AnyObject {
    func save(records: [CKRecord],
              savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
              isLongLived: Bool,
              perRecordProgress: @escaping (CKRecord.ID, Double) -> Void,
              operationIDHandler: @escaping (CKOperation.ID?) -> Void) async throws -> [CKRecord]

    func delete(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID]

    func fetch(recordIDs: [CKRecord.ID],
               desiredKeys: [CKRecord.FieldKey]?,
               perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord.ID: CKRecord]

    func query(recordType: String,
               predicate: NSPredicate,
               zoneID: CKRecordZone.ID,
               desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord]

    func fetchZoneChanges(zoneID: CKRecordZone.ID,
                          since token: CKServerChangeToken?,
                          desiredKeys: [CKRecord.FieldKey]?) async throws -> ZoneChangesResult

    func saveSubscription(_ subscription: CKSubscription) async throws

    func allLongLivedOperationIDs() async -> [CKOperation.ID]
    func reattachLongLivedOperation(id: CKOperation.ID) async
    func cancelAll()
}

// MARK: - Production implementation

/// Wraps a real `CKDatabase`/`CKContainer`, executing each call as a `CKOperation`.
public final class CKDatabaseAdapter: CloudKitDatabaseAdapter {

    private let container: CKContainer
    private let database: CKDatabase

    private let lock = NSLock()
    private var inFlight: [CKOperation] = []

    public init(container: CKContainer, database: CKDatabase) {
        self.container = container
        self.database = database
    }

    // MARK: Save / delete

    public func save(records: [CKRecord],
                     savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
                     isLongLived: Bool,
                     perRecordProgress: @escaping (CKRecord.ID, Double) -> Void,
                     operationIDHandler: @escaping (CKOperation.ID?) -> Void) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = savePolicy
            operation.qualityOfService = .userInitiated
            operation.configuration.isLongLived = isLongLived
            operationIDHandler(operation.operationID)

            var saved: [CKRecord] = []
            operation.perRecordProgressBlock = { record, fraction in
                perRecordProgress(record.recordID, fraction)
            }
            operation.perRecordSaveBlock = { _, result in
                if case .success(let record) = result { saved.append(record) }
            }
            operation.modifyRecordsResultBlock = { [weak self] result in
                self?.untrack(operation)
                switch result {
                case .success: continuation.resume(returning: saved)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    public func delete(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID] {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.qualityOfService = .userInitiated

            var deleted: [CKRecord.ID] = []
            operation.perRecordDeleteBlock = { recordID, result in
                if case .success = result { deleted.append(recordID) }
            }
            operation.modifyRecordsResultBlock = { [weak self] result in
                self?.untrack(operation)
                switch result {
                case .success: continuation.resume(returning: deleted.isEmpty ? recordIDs : deleted)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    // MARK: Fetch

    public func fetch(recordIDs: [CKRecord.ID],
                      desiredKeys: [CKRecord.FieldKey]?,
                      perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord.ID: CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
            operation.desiredKeys = desiredKeys
            operation.qualityOfService = .userInitiated

            var fetched: [CKRecord.ID: CKRecord] = [:]
            operation.perRecordProgressBlock = { recordID, fraction in
                perRecordProgress(recordID, fraction)
            }
            operation.perRecordResultBlock = { recordID, result in
                if case .success(let record) = result { fetched[recordID] = record }
            }
            operation.fetchRecordsResultBlock = { [weak self] result in
                self?.untrack(operation)
                switch result {
                case .success: continuation.resume(returning: fetched)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    // MARK: Query (handles cursor paging)

    public func query(recordType: String,
                      predicate: NSPredicate,
                      zoneID: CKRecordZone.ID,
                      desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord] {
        var all: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let (page, next) = try await runQuery(recordType: recordType,
                                                  predicate: predicate,
                                                  zoneID: zoneID,
                                                  desiredKeys: desiredKeys,
                                                  cursor: cursor)
            all.append(contentsOf: page)
            cursor = next
        } while cursor != nil
        return all
    }

    private func runQuery(recordType: String,
                          predicate: NSPredicate,
                          zoneID: CKRecordZone.ID,
                          desiredKeys: [CKRecord.FieldKey]?,
                          cursor: CKQueryOperation.Cursor?) async throws -> ([CKRecord], CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            let operation: CKQueryOperation
            if let cursor = cursor {
                operation = CKQueryOperation(cursor: cursor)
            } else {
                operation = CKQueryOperation(query: CKQuery(recordType: recordType, predicate: predicate))
            }
            operation.zoneID = zoneID
            operation.desiredKeys = desiredKeys
            operation.qualityOfService = .userInitiated

            var records: [CKRecord] = []
            operation.recordMatchedBlock = { _, result in
                if case .success(let record) = result { records.append(record) }
            }
            operation.queryResultBlock = { [weak self] result in
                self?.untrack(operation)
                switch result {
                case .success(let nextCursor): continuation.resume(returning: (records, nextCursor))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    // MARK: Zone changes

    public func fetchZoneChanges(zoneID: CKRecordZone.ID,
                                 since token: CKServerChangeToken?,
                                 desiredKeys: [CKRecord.FieldKey]?) async throws -> ZoneChangesResult {
        try await withCheckedThrowingContinuation { continuation in
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = token
            config.desiredKeys = desiredKeys
            let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID],
                                                              configurationsByRecordZoneID: [zoneID: config])
            operation.qualityOfService = .userInitiated

            var changed: [CKRecord] = []
            var deleted: [String] = []
            var newToken: CKServerChangeToken? = token
            var moreComing = false
            var zoneError: Error?

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result { changed.append(record) }
            }
            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                deleted.append(recordID.recordName)
            }
            operation.recordZoneChangeTokensUpdatedBlock = { _, serverToken, _ in
                if let serverToken = serverToken { newToken = serverToken }
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (serverChangeToken, _, moreComingFlag)):
                    newToken = serverChangeToken
                    moreComing = moreComingFlag
                case .failure(let error):
                    // Zone-scoped errors (`.changeTokenExpired`, `.zoneNotFound`)
                    // arrive HERE, not at the op level — there they'd be wrapped
                    // in `.partialFailure` and the token-expired recovery would
                    // never fire. Capture the bare error and throw it instead.
                    zoneError = error
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { [weak self] result in
                self?.untrack(operation)
                if let zoneError {
                    // We fetch exactly one zone, so its error IS the result.
                    continuation.resume(throwing: zoneError)
                    return
                }
                switch result {
                case .success:
                    continuation.resume(returning: ZoneChangesResult(changed: changed,
                                                                      deletedRecordNames: deleted,
                                                                      token: newToken,
                                                                      moreComing: moreComing))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    // MARK: Subscriptions

    public func saveSubscription(_ subscription: CKSubscription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription],
                                                           subscriptionIDsToDelete: nil)
            operation.qualityOfService = .utility
            operation.modifySubscriptionsResultBlock = { [weak self] result in
                self?.untrack(operation)
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    // MARK: Long-lived recovery

    public func allLongLivedOperationIDs() async -> [CKOperation.ID] {
        await withCheckedContinuation { continuation in
            container.fetchAllLongLivedOperationIDs { ids, _ in
                continuation.resume(returning: ids ?? [])
            }
        }
    }

    public func reattachLongLivedOperation(id: CKOperation.ID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            container.fetchLongLivedOperation(withID: id) { [weak self] operation, _ in
                if let databaseOperation = operation as? CKDatabaseOperation {
                    self?.track(databaseOperation)
                    self?.database.add(databaseOperation)
                }
                continuation.resume()
            }
        }
    }

    // MARK: Cancellation / tracking

    public func cancelAll() {
        lock.lock()
        let operations = inFlight
        inFlight.removeAll()
        lock.unlock()
        operations.forEach { $0.cancel() }
    }

    private func track(_ operation: CKOperation) {
        lock.lock(); inFlight.append(operation); lock.unlock()
    }

    private func untrack(_ operation: CKOperation) {
        lock.lock(); inFlight.removeAll { $0 === operation }; lock.unlock()
    }
}
