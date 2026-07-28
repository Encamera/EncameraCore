# AGENTS.md — CloudKit storage plane

Operating guide for LLM agents working in this directory. Read `README.md` first for the architecture and `MIGRATION.md` for how albums move in and out of CloudKit; this file is the rules of the road. Design rationale and the chunked build plan live in `plans/cloudkit-migration/` (`00-overview.md`).

## What this directory is

The CloudKit cloud-storage backend (Option A: one `EncMedia` record per media item, carrying encrypted index fields + an eager thumbnail asset + a lazy blob asset, in the user's **private** database, plus one `EncAlbum` record per album). It is one of three storage planes; `.local` and (until removal) `.icloud` (iCloud Drive) live elsewhere.

## Non-negotiable invariants — do not break these

1. **Ciphertext only.** Nothing but the existing ENC2 encrypted files and the keyed-hash `albumID` may reach CloudKit. Never upload plaintext, a plaintext album name, file path, or location. The crypto (`SecretFileHandlerV2`) is the privacy promise — CloudKit is transport only. If a change would put cleartext on a `CKRecord` or `CKAsset`, stop.
2. **`albumID` is `SyncedStoreEncryptionHandler` keyed hash**, deterministic and non-reversible — **not** the per-encryption `encryptedPathComponent`. If the hash can't be derived, fail closed rather than falling back to anything derived from `album.id` (which embeds the cleartext name).
3. **Lazy blob.** `encBlob` must never appear in `desiredKeys` for metadata sync or gallery enumeration. It is fetched only by an explicit `fetchBlob`.
4. **Commit the change token only after the index is durably saved.** The store is *pure* — it does not persist the token on fetch. The coordinator advances it post-save. Don't move that ordering.
5. **Never delete a local original without a fresh verification** that the record is in CloudKit with the right size. See `MIGRATION.md`; this is the single rule the whole migration is built around.
6. **Account-absent ⇒ local-only, never crash.** Anything other than `.available` means no-op gracefully. Mirror `CloudKitContainer`'s posture.
7. **`.local` and `.icloud` paths stay untouched** by changes in here.

## Architectural rules

- **Depend on the seam, not CloudKit.** All layers above the store talk to the `CloudKitMediaStoring` protocol (`CloudKitMediaStoring.swift`). Don't import or reference `CloudKit` types in the coordinator, file access, or app-level code — route new database operations through `CloudKitDatabaseAdapter` so they stay fakeable. Tests must never need the network or an iCloud account.
- **Names live in `CloudKitSchema.swift` only.** Never hardcode a record type, field, zone, or container id elsewhere. A rename happens in one place — and remember a new record type or field needs a Production schema deploy before a release build can write it (`Documentation/cloudkit-schema-deploy.md`).
- **Concurrency matches the codebase:** `actor` for storage/sync state (`CloudKitSyncCoordinator`, `CloudKitBlobCache`, `CloudKitFileAccess`), `@MainActor` for view models and the migration engine. The store uses `NSLock` for its defaults maps.
- **Reuse, don't reinvent:** crypto (`SecretFileHandlerV2` for metadata-bearing writes; **reads must use the format-agnostic `SecretFileHandler`** — V2 throws on V1-format blobs and legacy libraries are full of them, see ENC-135 and the `CloudKitFileAccess.swift` header), previews (`DiskFileAccess.createPreview`), the local index (`MediaIndexStore`), deterministic hashing (`SyncedStoreEncryptionHandler`), the gallery event bus (`FileOperationBus`). Extend these, don't fork them.
- **Two CloudKit records per Live Photo, one index entry.** Record names are `mediaID#<mediaTypeRawValue>` (see `CloudKitFileAccess.componentRecordName`); the `mediaID` groups them. Keep per-blob tracking and cache keys keyed by **record name**, not `mediaID`, or the two components collide.
- **The album record comes first.** `EncMedia` references its `EncAlbum` parent, and CloudKit rejects a save whose parent isn't on the server. Anything that creates media must ensure the album record exists (`saveAlbum` is idempotent) rather than assuming the reconciler already pushed it.

## Rules specific to the migration engine

Read `MIGRATION.md` before touching `CloudKitMigrationManager.swift`, `CloudKitMigrationPlan.swift`, or the launcher/resumer/registry in `Encamera/AlbumManagement/`. The short version:

- **Checkpoint after every state transition, not periodically.** One transition per write is what makes resume exact.
- **One run per album per process.** The engine's static active set is claimed atomically on the main actor. Don't add an `await` between the check and the claim, and don't let a second surface drive the same plan.
- **Cancel is durable, pause is not.** A cancel stamps `cancelledAt` so background auto-resume skips the plan; a pause leaves it freely resumable. Don't collapse the two.
- **Terminal states belong to `run()`.** Publishing `.completed` or `.failed` from planning tears the UI binding down before the work happens.
- **Publish progress through `publishProgress`/`setPhase` only.** A direct assignment silently drops the phase, and a phase that isn't published is invisible to the UI.
- **A surviving plan file always means unfinished business** — including one with no per-item work left, which means finalize failed and must be retried.
- **`.icloud` is not a migration source.** Evicted files enumerate as placeholders the engine would terminally skip. The guard in `plan(album:)` is deliberate.

## Build & test

The project is generated by **XcodeGen** from `project.yml`; this code lives in the `EncameraCore` SPM package. There is no `EncameraTests` *scheme* — `EncameraTests` and `EncameraCoreTests` are test targets on the `Encamera` scheme.

```bash
# After adding files / editing project.yml or *.entitlements:
xcodegen generate

# Unit tests (both unit targets)
xcodebuild test -scheme Encamera -destination 'platform=iOS Simulator,name=iPhone 16'

# Just one unit target
xcodebuild test -scheme Encamera -only-testing:EncameraCoreTests \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# UI tests (CloudKit UI tests run offline via -CloudKitMockMode)
xcodebuild test -scheme EncameraUITests -destination 'platform=iOS Simulator,name=iPhone 16'
```

Always re-run `xcodegen generate` after touching `project.yml` or any `*.entitlements`, or the change won't reach the project. The `EncameraDeviceSmoke` scheme and its environment variables are defined in `project.yml` — regenerate and diff rather than restoring a scheme file by hand.

## Testing rules

- Add unit tests at the `CloudKitMediaStoring` / `CloudKitDatabaseAdapter` seam with a fake — never hit a live container in automated tests.
- For UI-visible behavior, drive `InMemoryCloudKitMediaStore` via the `-CloudKitMockMode` launch arg (wired through `UITestSupport` / `CloudKitStoreProvider.makeStore`). `-CloudKitUploadDelayMs=N` and `-CloudKitDownloadDelayMs=N` slow a migration enough for the overlay to be observed.
- The device suites in `UITests/` (`CloudKitDeviceSuiteTests`, the migration progress/durability suites, `TwoDeviceCloudKitMigrationDeviceTests`, `CloudKitMigrationProductionWallDeviceTests`) hard-gate on environment variables set by the `EncameraDeviceSmoke` scheme and `Scripts/*.sh`, so they skip themselves everywhere else. Keep that gating when adding one.
- `CloudKitFlightCheck` is the only live-container path inside the app and is **manual** (a human runs it on a signed device from the debug workbench). Don't try to run it in CI; if you change a real code path it exercises, update the relevant step.

## Conventions (from the migration plan)

- Commit with the `modular-commits` skill: single-line imperative messages, no body, no attribution.
- Localize every user-facing string through `L10n` using the `encamera-localization-steps` skill.
- Use `perplexity-research` for CloudKit API details the plan didn't pin down.
- Keep anything user-visible behind a `FeatureToggle` until the plan flips it.

## Gotchas worth knowing before you edit

- **CloudKit owns the asset temp URL** and may delete it — copy the file out before the fetch returns (`CloudKitMediaStore.fetchAsset`).
- **The deleted-records list spans the whole shared zone** and carries no `albumID` — filter to records this album actually holds before acting.
- **A wiped index with a surviving change token** would skip every historical record forever — the coordinator detects this and forces a full resync. Don't remove that guard.
- **The zone-created flag is keyed by container id** — a container change (Debug vs Release, or a re-point) must recreate the zone. The flight check verifies the zone on the *server* rather than trusting the flag.
- **Missing thumbnail is allowed** (preview generation can fail); uploading a nil asset would fail the whole record, so the eager thumbnail is simply omitted.
- **Per-record errors arrive wrapped in `.partial`.** A single-record save that failed on quota or a missing account reports it as a partial failure, so a `switch` on the raw error never matches. Unwrap first (`CloudKitMigrationManager.unwrapPartial`).
- **`invalidArguments` on a save usually means an undeployed Production schema**, not a bad argument. That is a distinct, non-recoverable failure the user needs told about — don't fold it into a generic error.
- **Long-lived `CKOperation`s are gone (ENC-133)** and must not come back: re-enqueueing one raises an uncatchable `NSException` on the next launch. Background progress rests on the checkpoint plus a `BGProcessingTask`.
- **Use `CloudKitBlobCache.shared`.** A second instance writes the on-disk cache index from a divergent snapshot and orphans the other's blobs.

## When in doubt

Trust the code over the plan docs (they were written from a snapshot and can drift). If reality diverges from `plans/cloudkit-migration/`, follow the code and note the divergence. If a change touches the privacy invariants above, prefer to surface the concern rather than proceed.
