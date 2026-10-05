//
//  CloudKitMediaStoreError.swift
//  EncameraCore
//
//  Typed error model for the CloudKit store and the `mapCKError` translator that
//  turns raw `CKError`s into actionable cases (decision doc §5; chunk 02 §3).
//

import Foundation
import CloudKit

public enum CloudKitMediaStoreError: Error, CustomStringConvertible {
    /// No usable iCloud account — caller stays local-only. Never retry.
    case accountUnavailable
    /// iCloud storage is full. **Non-retryable** — surface to the user.
    case quotaExceeded
    /// Transient: wait `after` seconds and retry only the retryable parts.
    case retry(after: TimeInterval)
    /// A batch partially failed: `failed` maps record name -> its error. Records not
    /// listed succeeded and must be kept (critical for the migration engine).
    case partial(failed: [String: Error])
    /// The server copy changed under us; the coordinator resolves the conflict.
    case conflict(serverRecord: CKRecord?)
    /// The operation was cancelled (best-effort) — reconcile afterward.
    case cancelled
    /// A requested record or its asset was not present in the result.
    case notFound
    /// The custom zone is gone server-side (cleared iCloud data / deleted zone) —
    /// recreate it and retry.
    case zoneNotFound
    /// The stored zone change token is no longer valid — discard it and full-resync.
    case changeTokenExpired
    /// An operation that isn't supported for CloudKit albums yet (e.g. cross-album
    /// copy/move — handled in a later chunk). Fails loudly instead of corrupting.
    case operationNotSupported(String)
    /// Anything else, preserved for logging.
    case underlying(Error)

    public var description: String {
        switch self {
        case .accountUnavailable: return "CloudKit account unavailable"
        case .quotaExceeded: return "iCloud storage is full"
        case .retry(let after): return "Retry after \(after)s"
        case .partial(let failed): return "Partial failure (\(failed.count) failed)"
        case .conflict: return "Server record changed (conflict)"
        case .cancelled: return "Operation cancelled"
        case .notFound: return "Record or asset not found"
        case .zoneNotFound: return "CloudKit zone not found"
        case .changeTokenExpired: return "CloudKit change token expired"
        case .operationNotSupported(let what): return "Operation not supported for CloudKit: \(what)"
        case .underlying(let error): return "CloudKit error: \(error)"
        }
    }

    /// Whether a blind retry of the whole operation is ever appropriate.
    public var isRetryable: Bool {
        switch self {
        case .retry: return true
        default: return false
        }
    }
}

extension CloudKitMediaStoreError {

    /// What a `.partial` amounts to when its failed records agree, so a wrapped
    /// per-record error is classified the same as the bare one. `mapCKError`
    /// applies this to every partial failure it maps; call it directly only on a
    /// `.partial` built by hand.
    ///
    /// - Not `.partial`, or no failed records: `self`, unchanged.
    /// - One failed record: that record's error, mapped — whatever case it is.
    /// - Several failed records that all map to the same one of `.notFound`,
    ///   `.conflict`, `.quotaExceeded`, `.accountUnavailable`, `.zoneNotFound` or
    ///   `.changeTokenExpired`: that case. A collapsed `.conflict` carries no
    ///   server record, since there is more than one.
    /// - Anything else stays `.partial`, keeping exactly which records failed:
    ///   records not listed succeeded, and batch callers must keep them.
    public var unwrappingPartial: CloudKitMediaStoreError {
        guard case .partial(let failed) = self, !failed.isEmpty else { return self }
        let mapped = failed.values.map(mapCKError)
        if mapped.count == 1 { return mapped[0] }
        let kinds = Set(mapped.map(\.collapsibleKind))
        guard kinds.count == 1, let kind = kinds.first, let kind else { return self }
        switch kind {
        case .notFound: return .notFound
        case .conflict: return .conflict(serverRecord: nil)
        case .quotaExceeded: return .quotaExceeded
        case .accountUnavailable: return .accountUnavailable
        case .zoneNotFound: return .zoneNotFound
        case .changeTokenExpired: return .changeTokenExpired
        }
    }

    private enum CollapsibleKind: Hashable {
        case notFound, conflict, quotaExceeded, accountUnavailable, zoneNotFound, changeTokenExpired
    }

    private var collapsibleKind: CollapsibleKind? {
        switch self {
        case .notFound: return .notFound
        case .conflict: return .conflict
        case .quotaExceeded: return .quotaExceeded
        case .accountUnavailable: return .accountUnavailable
        case .zoneNotFound: return .zoneNotFound
        case .changeTokenExpired: return .changeTokenExpired
        default: return nil
        }
    }
}

/// Translate a raw error into the typed model. Pure and side-effect free so it is
/// trivially unit-testable with synthetic `CKError`s.
public func mapCKError(_ error: Error) -> CloudKitMediaStoreError {
    if let already = error as? CloudKitMediaStoreError { return already.unwrappingPartial }
    guard let ckError = error as? CKError else { return .underlying(error) }
    let userInfo = (error as NSError).userInfo

    switch ckError.code {
    case .quotaExceeded:
        return .quotaExceeded
    case .notAuthenticated, .managedAccountRestricted:
        return .accountUnavailable
    case .operationCancelled:
        return .cancelled
    case .unknownItem:
        return .notFound
    case .zoneNotFound, .userDeletedZone:
        return .zoneNotFound
    case .changeTokenExpired:
        return .changeTokenExpired
    case .serverRecordChanged:
        return .conflict(serverRecord: ckError.serverRecord)
    case .partialFailure:
        // Per-record failures (conflict, quota, unknownItem) and zone-scoped ones
        // (token expired, zone gone) reach the op level wrapped in
        // `.partialFailure`. Collapse the ones whose records agree, so a switch
        // on the typed case recognises them; see `unwrappingPartial`.
        var failed: [String: Error] = [:]
        for (key, value) in ckError.partialErrorsByItemID ?? [:] {
            if let recordID = key as? CKRecord.ID {
                failed[recordID.recordName] = value
            } else {
                failed["\(key)"] = value
            }
        }
        return CloudKitMediaStoreError.partial(failed: failed).unwrappingPartial
    case .zoneBusy, .serviceUnavailable, .requestRateLimited, .networkUnavailable, .networkFailure:
        let after = (userInfo[CKErrorRetryAfterKey] as? TimeInterval) ?? defaultRetryInterval
        return .retry(after: after)
    default:
        if let after = userInfo[CKErrorRetryAfterKey] as? TimeInterval {
            return .retry(after: after)
        }
        return .underlying(ckError)
    }
}

private let defaultRetryInterval: TimeInterval = 3
