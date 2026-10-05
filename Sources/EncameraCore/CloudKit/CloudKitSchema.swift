//
//  CloudKitSchema.swift
//  EncameraCore
//
//  Single source of truth for the CloudKit record/field/zone names used by the
//  CloudKit storage plane. This is the only place these literals are spelled —
//  every later chunk imports them so a rename here can never orphan deployed
//  schema. See plans/cloudkit-migration/01-cloudkit-foundations.md.
//

import Foundation

/// Canonical names for the Encamera CloudKit schema.
///
/// Privacy contract (see `00-overview.md` §schema):
/// - `albumID` is a random UUID minted once, when the album first becomes a
///   CloudKit album. It says nothing about the album; the name travels only as
///   `EncAlbum.encName`, ciphertext under the album key.
/// - `encThumbnail` and `encBlob` are ciphertext only (the existing ENC2 files).
///   No plaintext name, location, or content ever reaches CloudKit.
public enum CloudKitSchema {
    /// The single CloudKit container for the app, shared by both the debug
    /// (`me.freas.encamera-debug`) and release (`me.freas.encamera`) bundle IDs —
    /// a container is not bound 1:1 to a bundle ID, it just has to be listed in
    /// each App ID's iCloud entitlement.
    ///
    /// Isolation between debug and production data comes from the CloudKit
    /// **environment**, not the container: Xcode-run debug builds use the
    /// Development environment, distribution (TestFlight/App Store) builds use
    /// Production. Schema is authored in Development and promoted to Production via
    /// the CloudKit Dashboard's "Deploy Schema Changes" — see
    /// Documentation/cloudkit-schema-deploy.md.
    public static let containerID = "iCloud.app.encamera.Encamera"

    /// Custom record zone. A custom zone is mandatory for
    /// `CKFetchRecordZoneChangesOperation` delta sync.
    public static let zoneName = "EncameraZone"

    /// The single record type holding both the index fields and the two assets
    /// (Option A from the decision doc): one `CKRecord` per media item.
    public enum EncMedia {
        public static let recordType = "EncMedia"
        // record name == mediaID (a UUID string)
        public static let albumID        = "albumID"          // String, QUERYABLE + SORTABLE index
        public static let mediaID        = "mediaID"          // String
        public static let mediaType      = "mediaType"        // Int64
        public static let createdAt      = "createdAt"        // Date, QUERYABLE + SORTABLE
        public static let sizeBytes      = "sizeBytes"        // Int64
        public static let creationDevice = "creationDeviceID" // String
        public static let schemaVersion  = "schemaVersion"    // Int64
        public static let encThumbnail   = "encThumbnail"     // CKAsset (small, eager)
        public static let encBlob        = "encBlob"          // CKAsset (full ENC2, lazy)
        /// `CKRecord.Reference` to the owning `EncAlbum` record, with delete action
        /// `.deleteSelf` — deleting the album cascades to its media. The record's
        /// `parent` is set to the same reference for future record sharing. The
        /// plaintext `albumID` field above is retained as the queryable join key.
        public static let albumRef       = "albumRef"         // CKRecord.Reference(.deleteSelf)
        /// Lowercase hex of the 16-byte `KeyFingerprint` of the key this record's
        /// ciphertext was encrypted under — i.e. `PrivateKey.keychainLabel`. Needs no
        /// index: the census retrieves it via `desiredKeys` on a `createdAt`-filtered
        /// query and never filters on it. The fingerprint is a domain-separated
        /// BLAKE2b hash of the key bytes, so it discloses no key material and nothing
        /// about the plaintext.
        ///
        /// Absent or empty means "unknown", never "no key": records written before
        /// this field existed carry no value and are not backfilled, so readers must
        /// fall back to the `KeyDiscovery` sweep rather than fail.
        public static let keyFingerprint = "keyFingerprint"   // String
        /// The ENC3 header for a chunked video (framing only: magic, version, chunk
        /// size, plaintext length, chunk count, random file id, and the *encrypted*
        /// metadata section — no key material, no plaintext). Present exactly when
        /// the blob is chunked; a chunked record carries NO `encBlob`, its payload
        /// lives as `EncBlobChunk` records in `EncameraBlobZone`. Storing the header
        /// here lets a player learn the plaintext length — which AVFoundation
        /// demands before requesting a byte — with zero extra round trips, and
        /// makes saving this record the commit point: until `EncMedia` lands with
        /// `chunkCount` set, a partial chunk upload reads as "not chunked yet".
        public static let encHeader      = "encHeader"        // Bytes (ENC3 header)
        /// Number of `EncBlobChunk` records the blob occupies. 0/absent means
        /// monolithic (`encBlob` carries the whole ciphertext, as always).
        public static let chunkCount     = "chunkCount"       // Int64
        /// Plaintext byte length of a chunked video (duplicated out of `encHeader`
        /// so deletion and diagnostics never need to parse it).
        public static let plaintextLength = "plaintextLength"  // Int64
    }

    /// The album record. Makes CloudKit the authoritative, cross-device source of
    /// truth for which albums exist. The record name is the album's `albumID`
    /// UUID, the same value `EncMedia.albumID` carries, so the album↔media join
    /// needs no new id and `saveAlbum` is idempotent.
    ///
    /// Privacy: `encName` is the album-name ciphertext (the existing
    /// `Album.encryptedPathComponent`, encrypted with the album's own key). A device
    /// finds the album's key by decrypting `encName` under each synced key; the
    /// authenticated decrypt fails under every other key.
    public enum EncAlbum {
        public static let recordType = "EncAlbum"
        // record name == albumID (a UUID)
        public static let encName        = "encName"          // String (album name ciphertext)
        public static let createdAt      = "createdAt"        // Date
        public static let isHidden       = "isHidden"         // Int64 (0/1)
        public static let schemaVersion  = "schemaVersion"    // Int64
        /// The fingerprint of the key this album's media is encrypted under — the same
        /// value as `EncMedia.keyFingerprint`, recorded once per album so the key an
        /// album needs can be named without reading a media record. Same "absent means
        /// unknown" contract as above.
        public static let keyFingerprint = "keyFingerprint"   // String
        /// `CKRecord.Reference` to the `EncMedia` record the user chose as the
        /// album's cover image. Action `.none` — deleting the cover photo must not
        /// cascade-delete the album. Absent on records that predate this field or
        /// when no explicit cover is set.
        public static let coverMediaRef  = "coverMediaRef"   // CKRecord.Reference(.none) -> EncMedia
        /// 1 while a whole-album move to CloudKit is still filling the album, 0 once
        /// the moving device has finalized it. Another device leaves a flagged album
        /// unadopted, so it never lists a half-filled twin of an album it still shows
        /// in its old storage. Absent on records that predate the field, and on
        /// albums no move created; both read as 0.
        public static let migrationInProgress = "migrationInProgress" // Int64 (0/1)
    }

    /// Bumped when the record layout changes; written to `schemaVersion`.
    public static let currentSchemaVersion: Int64 = 1
}
