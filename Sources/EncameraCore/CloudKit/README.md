# CloudKit storage plane

This directory is Encamera's **CloudKit storage backend** — the cloud plane that
replaces iCloud Drive. It stores each media item as a single CloudKit record
(`EncMedia`) in the user's **private** database, carrying the encrypted index
fields plus two `CKAsset`s: a small eager **thumbnail** and the full **blob**.

> **Privacy invariant:** only ciphertext ever reaches CloudKit. The album name is
> reduced to a non-reversible keyed hash (`albumID`); the two assets are the
> existing ENC2 encrypted files. No plaintext name, location, or content leaves
> the device. CloudKit changes the *transport*, never the crypto. See
> `plans/cloudkit-migration/00-overview.md`.

This is **Option A** from the design decision: one `CKRecord` per media item
carrying both metadata and the blob, rather than a separate blob-transport plane.

## How it fits together

```
                 CloudKitFileAccess          ← FileAccess branch for `.cloudKit` albums
                 (encrypt → upload,            (reuses SecretFileHandlerV2 + DiskFileAccess preview)
                  lazy fetch → decrypt)
                        │
                        ▼
              CloudKitSyncCoordinator         ← per-album orchestration (an actor)
              (delta sync → MediaIndexStore,    dedups fetches, applies tombstones,
               blob residency, deletes)         single-flight sync
                  │                  │
                  ▼                  ▼
        CloudKitBlobCache     CloudKitMediaStoring  ← the protocol seam everything depends on
        (evictable local       │
         ciphertext cache)     ├── CloudKitMediaStore         (production)
                               │      └── CloudKitDatabaseAdapter → CKDatabaseAdapter (real CKOperations)
                               └── InMemoryCloudKitMediaStore  (tests / -CloudKitMockMode)
                        │
                        ▼
                 CloudKitContainer             ← account gating + idempotent zone bootstrap
                 CloudKitSchema                ← the one place record/field/zone names live
```

Two app-level helpers sit beside this stack:

- **`CloudKitCoordinatorRegistry`** hands out one coordinator per album id so the
  active album and the push fan-out share in-memory state.
- **`CloudKitAlbumsSync`** observes the `cloudKitZoneChanged` notification and
  reconciles *every* CloudKit album on a push (inactive albums included).

## The layers (bottom → top)

| File | Role |
|---|---|
| `CloudKitSchema.swift` | Single source of truth for the container id (Debug vs Release), zone name `EncameraZone`, the `EncMedia` record type, every field name, and `currentSchemaVersion`. Every other file imports these literals. |
| `CloudKitContainer.swift` | Provisioning only: account-status gating (stays local-only unless `.available`) and idempotent custom-zone creation. Injectable `AccountStatusProviding` / `RecordZoneProvisioning` seams keep tests off the network. No media I/O. |
| `CloudKitMediaStoreError.swift` | The typed error model + `mapCKError` translator that turns raw `CKError`s into actionable cases (`quotaExceeded`, `retry(after:)`, `partial`, `conflict`, `zoneNotFound`, `changeTokenExpired`, …). Pure, unit-testable. |
| `DeviceIdentity.swift` | Stable per-install id written to `creationDeviceID`, used to tell "I authored this" (keep local) from "fetch on tap". |
| `CloudKitDatabaseAdapter.swift` | Narrow database-operation protocol + the production `CKDatabaseAdapter` that wraps each call as a `CKOperation` (save/delete/fetch/query/zone-changes/subscription/long-lived recovery/cancel). Keeps the store free of `CKOperation` wiring; trivially fakeable. |
| `CloudKitMediaStoring.swift` | **The protocol seam.** The value types (`CloudKitMediaUpload`, `CloudKitMediaMetadata`, `CloudKitMediaRef`, `CloudKitChangeSet`) and the interface every downstream layer depends on — never CloudKit directly. |
| `CloudKitMediaStore.swift` | Concrete Option-A store: builds one `EncMedia` record (index fields + thumbnail + blob), uploads long-lived with progress, cheap asset-free metadata sync (`desiredKeys`), lazy blob/thumbnail fetch, hard delete + tombstone, change-token delta sync, push subscription, and interrupted-upload recovery. State lives in app-group defaults. |
| `InMemoryCloudKitMediaStore.swift` | Deterministic in-memory `CloudKitMediaStoring` for UI tests and offline verification. Never touches the network or an account. |
| `CloudKitBlobCache.swift` | The app-controlled, **evictable** local ciphertext cache (Caches dir, excluded from backup, LRU byte cap). Change-tag-aware: a remote re-upload invalidates the stale copy. One shared instance owns the on-disk index. |
| `CloudKitSyncCoordinator.swift` | Per-album actor that orchestrates everything: single-flight delta sync into the existing `MediaIndexStore`, dedup of concurrent blob fetches, tombstone-then-purge deletes, Live Photo two-component merge, and zone-subscription registration. |
| `CloudKitFileAccess.swift` | The `FileAccess` branch for `.cloudKit` albums. Save = encrypt (`SecretFileHandlerV2`) then upload; load = lazy fetch then decrypt; enumeration comes from the synced index (never the network); delete = tombstone + cross-device purge. Reuses the existing preview pipeline. |
| `CloudKitCoordinatorRegistry.swift` | One coordinator per album id, shared between the active album and the push fan-out. |
| `CloudKitAlbumsSync.swift` | App-level push fan-out: on `cloudKitZoneChanged`, reconcile every CloudKit album. |
| `CloudKitFlightCheck.swift` | A manual, end-to-end smoke test (12 ordered steps) that runs the *real* code paths with dummy data against a signed device — entitlement → account → zone → subscription → encrypt+upload → sync → **cold-cache** server download → thumbnail → delete+tombstone. Drives the `ICloudFlightCheckView` workbench behind the `iCloudFlightCheck` toggle. |

## Key invariants & design choices

- **Lazy blob, eager thumbnail.** Metadata sync and the gallery never request
  `encBlob` — only `desiredKeys` it excludes. The full blob is fetched on tap by
  a second op; the thumbnail is small enough to fetch eagerly so non-authoring
  devices render the grid before downloading full-res.
- **Custom zone is mandatory.** `EncameraZone` exists so
  `CKFetchRecordZoneChangesOperation` delta sync works (Apple's private-DB sync
  pattern). Bootstrap is idempotent and the "created" flag is keyed by container.
- **Change tokens are per-album.** The zone is shared across albums, but each
  album keeps its own cursor so syncing one album doesn't advance the others'.
  The store fetches purely; the coordinator commits the token **only after** the
  index is durably saved, so a mid-sync failure re-fetches rather than loses data.
- **Live Photos = two records, one entry.** A photo and video component share a
  `mediaID` but use distinct record names (`mediaID#type`). The coordinator
  merges them into one `MediaIndexEntry`.
- **Tombstone-beats-blob.** Deletes set `deletedAt` (propagates by push), clear
  local state, then hard-purge on the next sync. A delete that lands mid-fetch
  wins and the fetched copy is discarded.
- **Account-absent ⇒ local-only.** Anything short of `.available` means the app
  stays on its local plane; CloudKit calls no-op rather than crash.

## Tests

- **Unit tests** (XCTest) mock at the `CloudKitMediaStoring` / `CloudKitDatabaseAdapter`
  seams, so CI never touches the network or an iCloud account.
- **UI tests** run offline against `InMemoryCloudKitMediaStore` via `-CloudKitMockMode`.
- **`CloudKitFlightCheck`** is the *only* path that hits a live container, and it
  is manual (a human runs it on a signed device from the debug workbench).

## Where to start reading

1. `CloudKitSchema.swift` — the vocabulary (records, fields, zone).
2. `CloudKitMediaStoring.swift` — the contract every layer is written against.
3. `CloudKitSyncCoordinator.swift` — the orchestration and the hard-won invariants.
4. `CloudKitFileAccess.swift` — how the app actually saves/loads/deletes media.

Design rationale and the chunk-by-chunk build live in
`plans/cloudkit-migration/` (start with `00-overview.md`).
