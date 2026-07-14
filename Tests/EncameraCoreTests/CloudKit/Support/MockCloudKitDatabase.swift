//
//  MockCloudKitDatabase.swift
//  EncameraCoreTests
//
//  In-memory fake of `CloudKitDatabaseAdapter` plus small CloudKit test helpers,
//  so the store can be exercised offline with no iCloud account.
//

import Foundation
import CloudKit
@testable import EncameraCore

// MARK: - Account / zone stubs (reused across CloudKit tests)

struct StubAccountStatusProvider: AccountStatusProviding {
    let status: CKAccountStatus
    func currentAccountStatus() async throws -> CKAccountStatus { status }
}

final class StubZoneProvisioner: RecordZoneProvisioning {
    func saveZone(_ zone: CKRecordZone) async throws {}
    func deleteZone(_ zoneID: CKRecordZone.ID) async throws {}
}

// MARK: - Mock adapter

final class MockCloudKitDatabase: CloudKitDatabaseAdapter {

    // Captured inputs
    private(set) var savedRecordBatches: [[CKRecord]] = []
    private(set) var deletedRecordIDBatches: [[CKRecord.ID]] = []
    private(set) var lastSavePolicy: CKModifyRecordsOperation.RecordSavePolicy?
    private(set) var lastSaveLongLived: Bool?
    private(set) var lastQueryDesiredKeys: [CKRecord.FieldKey]?
    private(set) var lastFetchDesiredKeys: [CKRecord.FieldKey]?
    private(set) var reattachedIDs: [CKOperation.ID] = []
    private(set) var cancelAllCalled = false

    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    private(set) var fetchCount = 0

    // Programmable behavior
    var saveError: Error?
    var deleteError: Error?
    var fetchError: Error?
    var queryError: Error?
    var zoneChangesError: Error?

    var stubbedQueryRecords: [CKRecord] = []
    var stubbedFetchRecords: [CKRecord.ID: CKRecord] = [:]
    var stubbedZoneChanges: ZoneChangesResult?
    var saveProgressValues: [Double] = []
    var fetchProgressValues: [Double] = []
    var longLivedIDs: [CKOperation.ID] = []
    var operationIDToReport: CKOperation.ID? = "mock-op"

    func save(records: [CKRecord],
              savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
              isLongLived: Bool,
              perRecordProgress: @escaping (CKRecord.ID, Double) -> Void,
              operationIDHandler: @escaping (CKOperation.ID?) -> Void) async throws -> [CKRecord] {
        saveCount += 1
        lastSavePolicy = savePolicy
        lastSaveLongLived = isLongLived
        savedRecordBatches.append(records)
        operationIDHandler(operationIDToReport)
        for record in records {
            for value in saveProgressValues { perRecordProgress(record.recordID, value) }
        }
        if let saveError { throw saveError }
        return records
    }

    func delete(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID] {
        deleteCount += 1
        deletedRecordIDBatches.append(recordIDs)
        if let deleteError { throw deleteError }
        return recordIDs
    }

    func fetch(recordIDs: [CKRecord.ID],
               desiredKeys: [CKRecord.FieldKey]?,
               perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord.ID: CKRecord] {
        fetchCount += 1
        lastFetchDesiredKeys = desiredKeys
        for recordID in recordIDs {
            for value in fetchProgressValues { perRecordProgress(recordID, value) }
        }
        if let fetchError { throw fetchError }
        var result: [CKRecord.ID: CKRecord] = [:]
        for recordID in recordIDs where stubbedFetchRecords[recordID] != nil {
            result[recordID] = stubbedFetchRecords[recordID]
        }
        return result
    }

    func query(recordType: String,
               predicate: NSPredicate,
               zoneID: CKRecordZone.ID,
               desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord] {
        lastQueryDesiredKeys = desiredKeys
        if let queryError { throw queryError }
        return stubbedQueryRecords
    }

    func fetchZoneChanges(zoneID: CKRecordZone.ID,
                          since token: CKServerChangeToken?,
                          desiredKeys: [CKRecord.FieldKey]?) async throws -> ZoneChangesResult {
        if let zoneChangesError { throw zoneChangesError }
        return stubbedZoneChanges ?? ZoneChangesResult(changed: [],
                                                       deletedRecordNames: [],
                                                       token: token,
                                                       moreComing: false)
    }

    private(set) var savedSubscriptions: [CKSubscription] = []
    var saveSubscriptionError: Error?
    func saveSubscription(_ subscription: CKSubscription) async throws {
        if let saveSubscriptionError { throw saveSubscriptionError }
        savedSubscriptions.append(subscription)
    }

    func allLongLivedOperationIDs() async -> [CKOperation.ID] { longLivedIDs }

    func reattachLongLivedOperation(id: CKOperation.ID) async { reattachedIDs.append(id) }

    func cancelAll() { cancelAllCalled = true }
}

// MARK: - Record-building helpers

enum CloudKitTestFactory {
    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: CloudKitSchema.zoneName) }

    static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    static func encMediaRecord(recordName: String,
                               albumID: String,
                               mediaType: MediaType = .photo,
                               createdAt: Date = Date(timeIntervalSince1970: 1_000),
                               sizeBytes: Int64 = 1234,
                               deletedAt: Date? = nil) -> CKRecord {
        let record = CKRecord(recordType: CloudKitSchema.EncMedia.recordType, recordID: recordID(recordName))
        record[CloudKitSchema.EncMedia.albumID] = albumID as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaID] = recordName as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaType] = Int64(mediaType.rawValue) as CKRecordValue
        record[CloudKitSchema.EncMedia.createdAt] = createdAt as CKRecordValue
        record[CloudKitSchema.EncMedia.sizeBytes] = sizeBytes as CKRecordValue
        record[CloudKitSchema.EncMedia.creationDevice] = "test-device" as CKRecordValue
        record[CloudKitSchema.EncMedia.schemaVersion] = CloudKitSchema.currentSchemaVersion as CKRecordValue
        if let deletedAt { record[CloudKitSchema.EncMedia.deletedAt] = deletedAt as CKRecordValue }
        return record
    }
}

// MARK: - Synthetic CKError construction

enum CKErrorFactory {
    static func error(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> Error {
        NSError(domain: CKError.errorDomain, code: code.rawValue, userInfo: userInfo)
    }
}
