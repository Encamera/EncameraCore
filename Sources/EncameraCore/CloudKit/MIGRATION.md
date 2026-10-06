# Moving an album between this device and CloudKit

This is the story of a storage move, start to finish, in both directions — a whole album, or items selected inside one. `README.md` describes the CloudKit storage plane itself — how media is stored and synced once an album already lives there. This file describes how an album *gets* there, and how it comes back.

Design rationale and the chunk-by-chunk build live in `plans/cloudkit-migration/12-local-to-cloudkit-migration.md`. Where the plan and the code disagree, the code wins.

## Why a move is not a file move

Every other storage move in the app is a directory rename: the files are already on disk, so moving them is one atomic-ish operation that either works or doesn't. A CloudKit move is not that. It uploads every file over the network, one at a time, and then deletes the local original — so it takes minutes, it can be interrupted at any point, and half of it can succeed.

Two consequences drive the whole design:

1. **The move has to survive being interrupted.** The app can be killed, the phone can run out of battery, the network can drop. So the engine writes an encrypted checkpoint to disk after *every* single state change, and that checkpoint — not anything CloudKit remembers — is the source of truth for where the move got to.
2. **A local original is never deleted until its copy is confirmed present in CloudKit.** Upload, then verify by fetching the record back, then delete. If verification fails for any reason, the local file stays and the item is retried.

Because of this, `AlbumManager.moveAlbum(album:toStorage:)` — the ordinary synchronous move — *refuses* both CloudKit directions. Asking it to move something to CloudKit throws `migrationRequiredForCloudKit`; asking it to move a CloudKit album anywhere throws `downloadRequiredFromCloudKit`. Every caller has to go through the paths below.

## One engine, two scopes, two directions

Every transfer between local storage and CloudKit is a `MigrationPlan` run by `CloudKitMigrationManager`. A plan has a source and a destination endpoint (album name plus storage, and for a CloudKit endpoint the album's `albumID`), a scope, and a list of work items:

| | local or iCloud Drive → CloudKit | CloudKit → local |
|---|---|---|
| **Album scope** (`.album`, the whole album; finalize flips its storage) | `start(album:)`: upload → verify → delete the local original, per item; finalize writes the CloudKit marker | two passes: download and verify every item, *then* delete every record; finalize removes the CloudKit identity |
| **Item scope** (`.items`, selected media; finalize flips nothing) | upload → verify → delete the local original, per item | download → verify → delete the record, per item |

The direction follows from the storage pair, which the plan's initializer restricts to these two. Each direction has one `MigrationItemStep`: `LocalToCloudKitStep` and `CloudKitToLocalStep`, each with a `transfer` (`pending → verified`) and a `removeSource` (`verified → sourceDeleted`). The engine owns everything else — the loop, the preflights, checkpointing, progress, pause and cancel — for all four combinations.

In every combination the run is checkpointed after every state change, resumes after a kill (at launch, from a background slice, or from the banner), and reports through the same UI: the blocking overlay on the album screen, the floating progress pill, and the same `MigrationProgress` snapshot type.

Cancelling is safe at any time, with one exception: a whole album moving back to this device ignores a cancel once its second pass has started (see [Direction 2](#direction-2-cloudkit--local)).

## Where the pieces live

The engine and its checkpoint live in `EncameraCore` (this directory). Everything that drives it, shows it, or resumes it lives in the app target, because it needs SwiftUI, `BackgroundTasks`, and the shared background-task UI.

| File | What it does |
|---|---|
| `CloudKitMigrationPlan.swift` | The checkpoint: `MigrationItem` (one file's state machine), `MigrationPlan` (endpoints, scope, work list and progress maths), and `MigrationPlanStore` (encrypted, atomic read/write of plan files). |
| `CloudKitMigrationManager.swift` | The engine. Plans album-scope work, runs any plan item by item, checkpoints after every transition, handles pause/cancel/resume, finalizes, and publishes `state` + `progress`. Also owns the process-wide "which albums have a move running" set. |
| `MigrationItemStep.swift` | The per-item work of each direction: `LocalToCloudKitStep` and `CloudKitToLocalStep`. |
| `Encamera/AlbumManagement/CloudKitMigrationLauncher.swift` | Bridges the headless engine to the app: builds the pre-flight estimate, and for any plan (`start(plan:)`) registers a `MigrationTask` in the shared background-task UI and pumps engine progress into it. |
| `Encamera/AlbumManagement/CloudKitMigrationRunRegistry.swift` | Keeps each launcher alive for exactly as long as its run, keyed by album id. Without it, popping the album screen mid-move deallocates the launcher and the progress UI freezes. |
| `Encamera/AlbumManagement/CloudKitMigrationResumer.swift` | Finds interrupted checkpoints and drives each one to completion. Called at launch and from the background task. |
| `Encamera/AlbumManagement/CloudKitMigrationBackgroundTask.swift` | The `com.encamera.cloudkit-migration` background processing task — best-effort extra progress while the app is backgrounded. |
| `Encamera/AlbumManagement/MigrationStatusOverlay.swift` | The blocking, non-dismissible status view over the album grid, with phase, counts, ETA and Cancel. |
| `Encamera/AlbumManagement/PartialMigrationBanner.swift` | The persistent banner on an album whose move was stopped part-way, with Resume. |
| `Encamera/AlbumManagement/AlbumDetailView.swift` | The screen that starts every kind of move, binds the launcher, and decides when the overlay and banner are shown. |

Supporting pieces used by the move but owned elsewhere: `AlbumManager.finalizeMigrationToCloudKit` and `AlbumManager.finalizeMigrationToLocal` (the album flips), and `Album.cloudKitTwin(of:albumID:)` / `Album.localTwin(of:)` / `Album.removeDrainedSourceDirectory`.

---

# Direction 1: local → CloudKit

## What the user sees

1. On the album screen the user picks **iCloud** as the storage type and taps **Confirm Storage**.
2. The app shows a warning alert with an item count and a rough time estimate ("this may take over an hour"). Building that estimate does *not* write anything to disk, so backing out here leaves no trace.
3. On confirm, a full-screen overlay covers the album grid for the whole move. It shows a percentage ring, what the move is currently doing ("Uploading", "Verifying", "Removing local copy"), an "N of M" count, the total size, an ETA, and a **Cancel** button.
4. The grid is covered on purpose: mid-move the album is genuinely half-drained — some files have already had their local copies deleted — and showing that is more confusing than showing nothing.
5. If the user leaves the screen, the move keeps running and the floating progress pill takes over. Coming back to the album screen re-attaches the overlay to the same run.
6. When it finishes, the album flips to CloudKit and the screen adopts the new album.

`.local` albums are offered this directly. iCloud Drive albums go through the upgrade flow, and the engine downloads each batch of evicted files before uploading it — see [iCloud Drive sources are materialized first](#icloud-drive-sources-are-materialized-first).

## The checkpoint file

One file per plan, at:

```
~/Library/Application Support/CloudKitMigration/<sha256(source album.id)>/<plan id>.encplan
```

The plan id is `album` for album scope and a UUID for item scope. `album.id` includes the storage type, so an album's forward and reverse plans never share a directory. Each file is encrypted with the source album's key (the same encryption `MediaIndexStore` uses), written atomically, and excluded from backup. The directory name is a hash, so no album name appears on disk in the clear. `MigrationPlanStore.plans(for:)` lists every plan whose source is a given album, in both scopes.

The plan holds its id, the source and destination endpoints, the scope, when it was created, an optional `cancelledAt` stamp, a version, and the list of work items. Each item is one media *component* — a Live Photo contributes two, because a Live Photo is two CloudKit records — and carries the media id, the CloudKit record name, the file size, the current state, and the last error if any.

Two things about the file matter more than they look:

- **It is written after every state transition, not periodically.** That is what makes "resume exactly where it left off" true rather than approximate.
- **Its existence means unfinished business.** A completed migration deletes it. So any surviving plan file means either the move is half-done, or the move finished uploading but the final album flip failed and needs retrying.

## One item's journey

Each item walks a small state machine, and it can only advance one step per checkpoint write:

```
pending → uploading → uploaded → verified → sourceDeleted    ← done

pending → skipped        source ciphertext is missing, or   ← done, terminal
                         the record belongs to another album
  any   → failed         retryable; restarts as pending on the next run
```

What each step actually does:

- **pending → uploading.** The engine checks that the encrypted source file is still on disk. If it isn't, the item is marked `skipped` — terminally. A stale index entry pointing at a file that no longer exists must never wedge the whole album short of completion.
- **pending → skipped (foreign owner).** Before uploading, the engine asks `confirmAlbum` who owns the item's record name. If a record with that name already exists under a *different* album, the item is marked `skipped` with the reason in `lastError`, and the record is never re-parented. The local original stays, so that album shows in both storages until the user sorts it out. Every later read of the record checks its owner too: recovering an interrupted upload, the verify after an upload or an upload conflict, and the re-verify of a stale verification. A record another device moved to another album after this check is not this move's copy, so it skips the item the same way.
- **What the owner check cannot see.** `confirmAlbum` finds only committed records. Two devices uploading the same record name into different albums at the same moment each see no owner, and chunk records carry no album or file id, so an ENC3 upload's probe can keep chunks the other device saved. In practice the same media id means the same source file, whose ENC3 chunks are byte-identical, so keeping them is harmless; a re-encrypted legacy video overwrites every chunk and keeps none. Whichever `EncMedia` save lands second conflicts, and its device skips the item on the owner it then reads. What remains is two devices re-encrypting the same legacy video at once, whose overwrites can interleave under one header; the size-only verify does not catch that.
- **uploading.** The existing ciphertext is uploaded as-is, with one exception: a legacy (ENC1/ENC2) video at or above the chunking threshold is re-encrypted into a temporary ENC3 file so it lands as chunk records. An ENC3 source's chunk upload resumes by probe, keeping any chunk an earlier attempt saved, because every attempt sends the same bytes. A re-encryption has a new file id every attempt, so its upload rewrites every chunk (`ExistingChunkPolicy.overwrite`); the store refuses that rewrite with a conflict when the `EncMedia` record is already committed, and the engine falls through to verification as it does for any conflict. The upload goes through the same `CloudKitSyncCoordinator.upload` the live app uses, so the migrated album's index and blob cache end up exactly as a fresh save would leave them. CloudKit's "retry after N seconds" is honoured up to three times per item, and while waiting the UI shows "Retrying".
- **uploading → uploaded.** If the upload comes back with a *conflict* — a record with that name is already on the server, e.g. from an earlier run whose checkpoint was lost — that is not an error. The bytes are there; the engine falls through to verification rather than fighting the conflict.
- **uploaded → verified.** The record is fetched back by record id (a strongly-consistent read, not the eventually-consistent query), and its album and size are compared against the move's destination and the local file. A record in another album skips the item. Anything else short of "present in this album with the right size" fails it. Either way the local original is left alone.
- **verified → sourceDeleted.** The local encrypted file is deleted. This is the only irreversible step, so two guards sit in front of it: a cancel requested mid-item stops here rather than deleting, and an item that entered this run *already* `verified` (from an earlier run) is re-verified first, album included — that old verification could be arbitrarily stale, since the record may have been deleted, or moved to another album, from another device since.

The preview thumbnail is **not** deleted along with the original. Previews live in a global, storage-agnostic thumbnail directory that the migrated CloudKit album reads from the same path, so deleting them would force a re-download of every thumbnail — and for a Live Photo would strip the shared preview before its second component uploads.

## Planning and re-planning

`plan(album:)` enumerates every encrypted component in the album, gives each one a stable media id and a deterministic CloudKit record name, and merges that fresh list into whatever plan already exists on disk.

The merge rules are what make a resume safe:

- Items that already made progress (`uploading`, `uploaded`, `verified`, `sourceDeleted`, `skipped`) keep their state.
- Items that were `pending` or `failed` restart as `pending` with a freshly-read file size.
- Items in the old plan that enumeration can no longer see are **kept** if they made progress, and dropped if they didn't. A `sourceDeleted` item has no source file left to enumerate — dropping it would let the album finalize as if that item had never existed.

Because record names are derived from the media id rather than allocated, re-planning never produces a duplicate upload.

## Which CloudKit album the move lands in

A CloudKit album is identified by its `albumID`, a UUID that is the `EncAlbum` record name, the `EncMedia.albumID` join key, and the key for everything local (blob cache folder, `album.json`, index, sidecars, change token). The first `plan(album:)` resolves it (`resolveCloudKitAlbumID`) and persists it in the plan's destination endpoint (`MigrationEndpoint.cloudKitAlbumID`); every later re-plan and resume reuses that id, so a resumed move can never land in a second album. The rule is resolve-or-mint, in this order:

1. A CloudKit album already on this device (an `album.json`) whose `encName` decrypts under the album's key to the same name.
2. A server `EncAlbum` found by `fetchAllAlbums` whose `encName` decrypts under the key to the same name, skipping albums this device has queued for deletion. The earliest `createdAt` wins a tie. Adopting it means two devices moving the same album upload into one album, not two with the same media record names.
3. Otherwise a new UUID.

If the server's albums can't be listed, planning fails with `cloudKitAlbumLookupFailed` rather than minting: a blind mint would split the album whenever another device already moved it. Two devices that both mint within seconds of each other still end up with two albums; that race is accepted.

Before the first upload the engine saves the `EncAlbum` record under that id. For an album this device already holds it is built from `album.json`; otherwise `encName` is the local directory's name ciphertext, byte for byte, with the source album's hidden flag and cover.

A whole-album move saves that record with `migrationInProgress = 1`. Until the move finalizes, the album it is filling is kept out of every album list, because a half-filled second "Vacation" invites the user to delete it as a duplicate, and the record's `.deleteSelf` cascade would take every item already moved, whose originals are gone:

- `CloudKitAlbumReconciler` does not adopt an album that this device's plan names as its destination (`MigrationPlanStore.planRole(forAlbumID:)`), or whose record is flagged `migrationInProgress` (another device's move). It adopts it on the first pass after the flag is cleared and the plan is gone.
- `AlbumManager.delete(album:)` throws `AlbumError.moveInProgress`, touching nothing, for an album that is the source or destination of a whole-album plan on this device (running, paused or failed) or that any running move holds; the album screen shows why. A delete that started before the move did is left queued, and the reconciler issues it only after `CloudKitAlbumMembership` finds the album empty.

## Finishing: the album flip

When no item has work left, a whole-album move first saves the album record with `migrationInProgress = 0`, so other devices adopt the album; if that save fails the run fails with the checkpoint kept, and the resume retries it. Then `AlbumManager.finalizeMigrationToCloudKit` flips the album's *identity* — the bytes are already in CloudKit and in the on-device blob cache:

1. Write the album's marker, `CloudKitStorageModel.albumsURL/<albumID>/album.json` (`CloudKitAlbumMarker`). It holds `encName`, `createdAt`, the hidden flag and cover carried over from the local album, the key fingerprint, and `dirty = true`. If an `album.json` for that id already exists (the move adopted an album this device holds), it is kept as is. The marker is the **only** way this device finds a CloudKit album, so if writing it fails the whole finalize fails.
2. Push the `EncAlbum` record from the marker, in the background, so the album shows up on the user's other devices. A successful save clears `dirty`; a failed one leaves it for the reconciler to retry.
3. Remove the drained source directory — but only if it contains no regular files — and with it the local album's name-keyed hidden flag and cover in `AlbumsSyncedStore`. A file the plan never enumerated is left in place rather than destroyed, which means the album simply stays visible in its old storage instead of losing data.
4. Delete the now-stale source index and the checkpoint file, and broadcast the change so the grid refreshes.

If step 1 throws, the checkpoint is deliberately **kept**. The album's bytes are safe in CloudKit but unreachable on this device without the marker, so the next resume retries the finalize. This is why "a plan with no remaining item work" is still treated as pending work.

There is one exception. A plan with zero items for an album whose `album.json` already exists is not an empty album — it is a re-run against an album that already finished. That plan is deleted without re-finalizing.

## Stopping: cancel, pause, and failure

These are three different things and the difference matters.

**Cancel** is a user action, and it is durable. The engine stops at the next safe boundary (never mid-item), reverts any item that was mid-upload back to `pending`, and stamps `cancelledAt` on the plan. An item move back to this device also discards the local copy of every item whose record it did not get to delete (see [Item-scope plans](#item-scope-plans)). The checkpoint is kept so the user can finish the move later, but automatic background resume deliberately skips a cancelled plan — the app must not quietly restart something the user explicitly stopped. Cancel always routes through the background-task manager rather than calling the engine directly, so the floating pill is finalized instead of being orphaned.

**Pause** is the system asking for the app's time back — specifically, a background processing slice expiring. The engine checkpoints at the next item boundary and stops. Nothing is stamped, so the plan stays freely resumable.

**Failure** comes in two flavours. Run-halting failures — iCloud storage full, no iCloud account, the CloudKit production schema never deployed — stop the whole run and surface a blocking alert with a **Resume** affordance; the user fixes the cause and resumes. Everything else fails just that item, records the error on it, and lets the run continue; at the end the run reports "N item(s) failed" including the first item's actual error.

Resume on that alert restarts the run that failed. The launcher keeps the failed plan (`blockedPlan`) beside `blockingReason`, and the alert carries it. A failed item move, in either direction, resumes from its own checkpoint, so the rest of its source album stays where it is; only a failed whole-album migration re-plans the album. An item move that has since finished or been discarded has nothing to resume, and Resume refreshes the album's grid and banner instead.

`quotaExceeded`, `accountUnavailable` and friends usually arrive wrapped in a CloudKit *partial failure*, because a save is a `CKModifyRecordsOperation` whose per-record errors are reported that way. `mapCKError` (through `CloudKitMediaStoreError.unwrappingPartial`) unwraps single-record partials so those cases are actually recognised, and unwraps multi-record partials only when every record agrees.

## Resuming

There are three ways an interrupted move gets picked back up — any scope, either direction:

1. **At launch.** `CloudKitMigrationResumer.resumePending` asks the engine for every non-cancelled plan (`pendingPlans()`) and drives each one through `CloudKitMigrationLauncher.start(plan:)`. It does not return until they have actually finished, because the background task handler awaits it before reporting its slice complete.
2. **In the background.** A `BGProcessingTask` (`com.encamera.cloudkit-migration`) requests processing time. Scheduling is gated on work actually existing — a slice is requested when a move starts or when a checkpoint is found at unlock, and the handler only re-arms while a checkpoint remains. Waking the app forever for users who never migrate would burn the background budget iOS uses to decide whether to grant a slice when a real move needs one. This is *best effort*; correctness comes from the checkpoint and launch-time resume. Long-lived CloudKit operations, which used to continue while suspended, were removed in ENC-133 because they crashed the app on the next launch.
3. **From the banner.** An album with a stopped, partly-finished move shows a persistent banner on its screen with the counts and a Resume button — the album banner for an album-scope plan, the media-move banner for an item-scope one. This is the only surface that mentions a user-cancelled move, since auto-resume skips it. It replaced a one-shot alert that could be dismissed into oblivion.

## Rules that must not break

- **Only one run per album per process.** `CloudKitMigrationManager` keeps a static set of album ids with a run in flight. A run claims both its source and destination atomically (no `await` between the check and the insert), and a second start touching either album returns `false` without changing any state. Two runs against one plan would clobber the checkpoint and double-upload or double-delete.
- **Never publish a terminal state from planning.** A resume whose only remaining work is a retried finalize would otherwise report `.completed` before the run even starts, tearing the UI binding down early and swallowing a second finalize failure. Terminal states belong to `run()`.
- **Progress goes through one funnel.** `run()` rebuilds the progress snapshot before and after every item, so a phase written directly into `progress` gets clobbered on the next loop turn. The phase lives on the manager and every publish goes through `publishProgress`. A phase that is only recorded and not published is invisible until the next item boundary, by which point it is already stale — so `setPhase` does both.
- **A phase is what marks a run as live.** `progress` is a non-optional published value that starts empty, so merely subscribing replays that empty snapshot. The overlay therefore requires a phase, not just a snapshot — otherwise it appears over "0 of 0" before planning has finished.
- **Resolve the album id once, and never mint blind.** The id is persisted in the plan the first time it is resolved, and a failed server lookup fails the plan. Minting again on resume, or minting without looking, would create a second album for the same media.
- **The album record must exist before any media uploads.** Every `EncMedia` record references its `EncAlbum` parent, and CloudKit rejects a save whose parent isn't on the server yet. The engine saves the album record itself (idempotently) rather than waiting for the reconciler to get there on its own schedule.
- **Use the shared blob cache, not a fresh instance.** Separate instances write the cache index from divergent snapshots and clobber each other, and a private cache would leave the shared one ignorant of the migrated blobs — breaking the "the blob is in the on-device cache" claim that makes the local delete safe.

---

# Direction 2: CloudKit → local

A whole CloudKit album moves back to this device through the same engine, as an album-scope plan with a CloudKit source. `CloudKitMigrationLauncher.moveToLocal(album:)` builds it and awaits the run.

1. **Reconcile the index first.** A record another device uploaded moments ago has to be included, or it would be left orphaned in the cloud. A *failed* reconcile aborts the run — the plan is built from the local index, so a stale or empty index (fresh device, transient error) would move nothing and still delete the album.
2. **Check the name is free.** The move becomes the local directory named by the album's current `encName`, so if any other album on this device (hidden ones included) already has the name, the run fails with `L10n.albumExistsError` before anything is transferred.
3. **Plan from the index.** Every component in the synced index becomes an item, sized from the album's size sidecar, and is merged into any checkpoint left by an earlier run exactly as the forward direction merges.
4. **Pass 1: transfer.** Items land in the local album directory named by `encName`. `CloudKitToLocalStep.transfer` materializes each ciphertext into the local layout, downloading anything not in the blob cache, and verifies the copy against the ciphertext length of the record on the server (`fetchRecordMetadata`; a chunked record's length comes from its header, since `sizeBytes` keeps a re-encrypted legacy video's original size). It never verifies against the cached blob it copied from, which would agree with a copy of a truncated cache entry. On a mismatch the cached blob is evicted and the item fails, so the next run downloads it again. A capture still waiting in this device's upload queue has no record yet: it is copied from its durable queue file and verified byte for byte against that file. Any other record the server does not have fails the item and deletes nothing. A file already at the destination that is as long as the record's ciphertext is this item's copy from an earlier run and is kept; anything else there is replaced by staging the new copy and swapping it in, never by deleting first. A record gone from CloudKit is `skipped`. Previews aren't copied — they already live in the shared thumbnail directory.
5. **The point of no return.** A cancel is honoured at every item boundary through pass 1 and once more here. Before this line, cancelling is free: the local copies are just redundant bytes and the album is still whole in CloudKit. Pass 2 only starts when every item is verified (or skipped); a failed item ends the run with every record in place.
6. **Pass 2: remove the records.** Every verified item's record is deleted. A cancel is ignored from here on — stopping part-way would leave the album half-deleted in the zone while it still reads as CloudKit on this device — but a pause still stops at an item boundary, and a resume that finds every item verified comes straight back to this pass. A failed delete keeps its item `verified` and ends the run. Every item's local copy is checked before its record goes, including one verified earlier in the same run: the user or another part of the app may have removed or damaged it since. An item verified by an earlier run is checked against the record's ciphertext length; one verified in this run against the size it had at verification (`MigrationItem.verifiedSizeBytes`), which needs no request. A copy that is missing or no longer matches is downloaded again first, and its record stays until the new copy verifies. A queued capture's "record removal" cancels its queue entry (and deletes the record too, if the upload landed in the meantime).
7. **Check for members the plan does not cover.** Finalize deletes the album record, and every `EncMedia` parents to it with `.deleteSelf`, so the server deletes every record still pointing at it — including ones this plan never saw: a capture or import from another device after planning, a record this device's index dropped, a capture still in this device's upload queue. Before finalizing, `CloudKitAlbumMembership.members(ofAlbumID:store:uploadQueue:)` reads the album's members from a full zone-changes fetch (strongly consistent, unlike the `fetchMetadata(albumID:)` query) plus the upload queue. Anything the plan has not removed is merged in as `pending` and the run goes back through both passes. After `maxMoveBackPasses` (3) passes that each found new members the run fails with the album record and every remaining record intact and the new members checkpointed, so a resume picks them up. While the run is in flight this device refuses new members outright: `CloudKitFileAccess` save and move throw `AlbumMoveGuardError.moveInProgress`, the camera disables its shutter with an explanation, and the destination pickers leave the album out (all through `MigrationPlanStore.refusesNewMedia(albumID:)`, the running-only shortcut for `planRole(forAlbumID:).refusesNewMedia`).
8. **Finalize.** `AlbumManager.finalizeMigrationToLocal(album:movedRecordNames:)` runs the same membership check itself and throws `AlbumError.albumStillHasMembers`, touching nothing, if anything but the records the move removed still points at the album, or if the check cannot reach the server. Only then does it delete the album record, awaited rather than fire-and-forget: the retry queue is device-local, so relying on it here would let a fresh install rematerialize the album before this device got around to retrying. If the delete fails, it stays queued, marked `requiresNoMembers`, so the reconciler retries. Another device can add media to the album until the queued delete lands, so the reconciler runs the same membership check first: an empty album is deleted, one that has members again keeps them (the delete intent is dropped and the album is adopted here like any other), and a check that cannot reach the server leaves the delete queued. Then it drops the CloudKit identity locally — `albums/<albumID>/`, the blob cache directory, both stale indexes and the sidecars — moves the hidden flag and cover from `album.json` into `AlbumsSyncedStore` under the album's name, and the disk scan rebuilds the local index from the moved files. The `albumID` is gone; a later move back to CloudKit resolves a new one. A failed finalize keeps the checkpoint for the next resume, as the forward direction does.

The two passes exist because the local album is invisible on this device until finalize removes its `album.json`. Its directory exists from the start of the run, so `AlbumManager.fetchAlbumsFromSources` leaves out a local album while `MigrationPlanStore.planRole(forAlbumID:)` names it the destination of a move back and the CloudKit album it is the twin of is still listed; the album list shows only the CloudKit album. A cancelled move keeps its plan, so the twin stays hidden until a resume finishes the move. Deleting a record per item would take it off every other device while this one cannot show it yet. An item-scope move back to this device has no such problem — both albums stay visible — so it removes each record as soon as its local copy verifies, with the same re-check for an item verified by an earlier run. When such a move stops with an item's record still in CloudKit — a cancel, or an item that failed — the engine discards that item's local copy, but only while the record is confirmed on the server, and the item downloads again on a resume. Otherwise the item would show in both albums, and a user deleting the duplicate would leave only the record, which the resume would then have deleted. A whole album keeps its copies, since its local album is invisible until finalize.

The launcher registers a `MigrationTask` with `direction: .toLocal`, so the pill says "Moved to this device". Failures surface as the move-failed alert, deliberately *not* as the blocking migration failure — that one's Resume button resumes a whole album by re-planning it as a move to CloudKit.

---

# What both directions share

**The overlay** (`MigrationStatusOverlay`) is shown when three things are true at once: the feature is enabled, the engine's active set contains this album, and there is a progress snapshot carrying a phase. Any one alone is wrong — the active set is true during the pre-run planning window when there's nothing to show, and a snapshot could outlive a run that already ended.

**The floating pill** and the overlay are mutually exclusive (`shouldShowFloatingPill`): one run must never be reported twice on the same screen.

**The registry** is what lets a screen bind to a run it didn't start. The album screen subscribes to the registry's published launchers and re-binds whenever the launcher for its album changes — which is how an auto-resumed migration, started by the resumer before the screen existed, still drives that screen's overlay.

**Erase** interacts with both. `EraserUtils` calls `requestAbortAll()` first, which makes every in-flight run halt at its next item boundary *without* writing another checkpoint (the wipe removes them all) and refuses new starts. It then clears every plan file, cancels any pending background task request, and — for a full erase — deletes the CloudKit zone. If deleting the user's cloud data fails while they plausibly have some, a marker is persisted so the app can warn them later.

---

# Testing

Nothing in the automated suites touches a live CloudKit container.

**Unit tests** (`EncameraCoreTests/CloudKit/`, `Tests/`) mock at the `CloudKitMediaStoring` seam:

- `CloudKitMigrationManagerTests` — the engine: durable cancel, resume from every item state, missing-source `skipped`, stale-verification recovery, partial-failure unwrapping, finalize-failure keeping the checkpoint, empty-album completion, and the two-pass album move back to local.
- `CloudKitMediaMoveTests` — item-scope moves in both directions.
- `CloudKitMigrationPlanTests` — the plan's shape and validation, progress maths, file locations, and the encrypted store's round-trip and failure modes (including superseded checkpoint versions).
- `CloudKitMigrationResumerTests`, `CloudKitMigrationRunRegistryTests`, `CloudKitMigrationBackgroundSchedulingTests` — resume, launcher lifetime, and when a background slice is requested and re-armed.
- `AlbumDetailMigrationBindingTests`, `AlbumDetailMoveFailureTests` — the overlay/banner/pill predicates and the move-failed alert routing.
- `AlbumDetailBlockedMoveResumeTests` — Resume on the blocking alert restarts the run that failed: an item move in either direction, or a whole album.

**UI tests** run offline against `InMemoryCloudKitMediaStore` via `-CloudKitMockMode`. `CloudKitMigrationUITests` covers migrate → cancel → banner → resume and the move back to this device, including a kill mid-move resumed on relaunch; `CloudKitMediaMoveUITests` covers item moves. `-CloudKitUploadDelayMs` and `-CloudKitDownloadDelayMs` slow the run just enough for the overlay to be observable, and `-CloudKitMockPersist` keeps the mock zone across a relaunch.

**Device suites** need a signed device and a real iCloud account, and are run by hand:

- `CloudKitDeviceSuiteTests` — flight check, native CloudKit albums, delete propagation.
- `CloudKitMigrationProgressDeviceTests`, `CloudKitMigrationDurabilityDeviceTests` — progress/cancel/banner/resume, and checkpoint survival across a state-preserving relaunch.
- `TwoDeviceCloudKitMigrationDeviceTests` (via `Scripts/two-device-cloudkit-migration-test.sh`) — migrate on one device, verify on the other.
- `CloudKitMigrationProductionWallDeviceTests` (via `Scripts/production-wall-device-test.sh`) — runs against the **Production** CloudKit environment to catch an undeployed schema, which is exactly the failure that never shows up in Development.

The engine reports a machine-readable marker (`UITestMigrationProgress`) with the verified/total counts, the current phase, the engine state, and the count of background slices actually granted — so a device test can tell "iOS never scheduled us" apart from "the migration is stuck".

---

# Things that surprise people

### iCloud Drive sources are materialized first

An iCloud Drive album's files can be evicted, in which case enumeration sees a placeholder but the bytes are not on the device — so an engine that treated them like local files would mark every evicted item `skipped` and then finalize, stranding those files in a directory the flipped album no longer surfaces. So for an `.icloud` source the engine downloads each batch of files before uploading it, sizes evicted files from iCloud's metadata index, and fails (rather than skips) a file that is still a placeholder. On a stop it evicts what it downloaded but never uploaded.

Separately: iCloud Drive is a dead end as a *destination* — unconditionally, not gated on the CloudKit flag — but existing iCloud Drive albums stay fully readable and writable. Those are two different questions and they have two different functions — `isStorageTypeOfferedForNewAlbums` versus `isStorageTypeAvailable`.

### A cancelled plan is kept, not deleted

Cancelling stops the move but keeps the checkpoint, so any item that already reached CloudKit is recovered when the user resumes rather than being re-uploaded. What the cancel changes is that *automatic* resume skips it.

### "No remaining work" does not mean "finished"

Completion deletes the checkpoint. So an album-scope plan on disk with every item `sourceDeleted` means the transfers finished but the album flip didn't — and it must be retried, or the album is safe in CloudKit and reachable nowhere on the device.

### A fresh engine is built for every run

The launcher never reuses a manager. A cached one still holds its previous terminal state, which a new subscription replays immediately — tearing the UI binding down before the resumed run has started.

### Migrated albums can hold V1-format blobs

The migration uploads the on-disk ciphertext verbatim, and a legacy library is full of V1-format files. That is why CloudKit *reads* must use the format-agnostic `SecretFileHandler` and never `SecretFileHandlerV2`, which throws on V1. See ENC-135 and the header of `CloudKitFileAccess.swift`.

---

# Media moves (cross-plane)

Everything above describes moving a *whole album* between local and CloudKit. A media move is different: the user selects individual items in one album, picks a target album, and the items move — potentially across a storage boundary. The path depends on whether the two albums live in the same storage plane or not.

## Routing

`AlbumDetailViewModel.moveSelectedMedia(to:)` inspects the source and target storage types:

| source | target | path |
|---|---|---|
| local | local | `FileMoveHandler` — synchronous per-item file move, floating pill |
| cloudKit | cloudKit | `FileMoveHandler` — server-side re-parent, no bytes move (see [CloudKit-to-CloudKit moves](#cloudkit-to-cloudkit-media-moves)) |
| local | cloudKit | the engine — an item-scope `MigrationPlan`, with the overlay |
| cloudKit | local | the engine — an item-scope `MigrationPlan`, with the overlay |

Same-plane moves are synchronous and cheap; cross-plane moves go through the engine and the migration overlay, because they carry the same durability requirements as a whole-album migration.

## Item-scope plans

`MigrationPlan.items(source:destination:media:)` builds the plan from the selection, one item per component (a Live Photo is two). It lives beside the source album's other plans under a UUID and is encrypted with the source album's key.

The run is the one described above, per item, in either direction: the step transfers and verifies the item, then removes its source copy straight away. Both albums stay visible throughout, so a cancelled move leaves the selection split between them, with every item in exactly one. After each item's `sourceDeleted` the engine keeps the indexes current — for a move to CloudKit it removes that component from the source index (`removeComponent`) and emits `didDelete` only once the entry is gone; for a move to local it upserts the destination index and emits `didCreate` — so both grids update as the move lands. A Live Photo therefore stays in the source grid until both halves have moved: if the video fails, the entry keeps its video component, whose file is still on disk. A run killed between an item's `sourceDeleted` checkpoint and that index write leaves the entry naming a file that is gone, so an item-scope move to CloudKit first clears the source component of every `sourceDeleted` item that the index still lists. Finalize flips nothing: the plan is deleted once no item has work left.

Both album ids are claimed in the engine's active set, so the overlay's `isMigrating` predicate holds on both album screens and no other run can start on either album mid-move. Cancel is durable and pause is not, exactly as for an album. A cancelled move shows a persistent partial-move banner on the source album ("N items were moved to <destination>, M are still here") with a Resume button.

## Reading a moved item: the key is per record

No move re-encrypts. A move into CloudKit uploads the file's ciphertext as it is, and a CloudKit-to-CloudKit move only re-parents the record, so a CloudKit album can hold records written under a key other than its own. `CloudKitFileAccess` therefore resolves the key per record (`CloudKitRecordKeyResolver`), never from the album alone. It tries the key this record resolved to earlier in the session, then the album key, then the key library with the record's `keyFingerprint` first, and a key counts only once it authenticates the content. The proof uses bytes the read already holds: the first block of the downloaded file for a full decrypt, or the ENC3 header and chunk 0 that streaming fetches before a player exists. The fingerprint is a hint, not the answer, because the AEAD does not cover it. When no held key opens the record, the read throws `FileAccessError.missingKeyForMedia`, naming the key from the file's stamp or the record's fingerprint, and the lightbox shows the missing-key prompt. A record stamped with a key the device holds that still fails is damage, not a missing key, and fails as a decrypt error. Thumbnails already resolved their key per file through `DiskFileAccess`.

## The launcher and overlay

`CloudKitMigrationLauncher.start(plan:)` registers a `MigrationTask` named for the destination, binds `$progress`/`$state` from the engine, emits the `UITestMigrationProgress` marker, and registers the run under **both** album ids so re-entering either screen finds it. The overlay is bound on the **source** album screen. The floating pill is suppressed while the overlay is up (`shouldShowFloatingPill`).

---

# CloudKit-to-CloudKit media moves

When both albums are CloudKit, no bytes move. `CloudKitFileAccess.move(media:progress:)` on the target facade does a server-side re-parent:

1. `store.reassignAlbum([recordName], toAlbumID: target.albumID)` — rewrites `albumID`, `albumRef` and `parent` on the server; assets are untouched.
2. `store.confirmAlbum(recordName:)` must return the target's `albumID` before any local state changes. This is the strongly consistent gate.
3. Locally: `cache.relocate(recordName:toAlbumID:)` moves the blob-cache entry; the target `MediaIndexStore` and `AlbumSizeSidecar` are upserted; `bus.didCreate` fires.
4. The source index heals through the coordinator's moved-away rule on the next sync. An explicit `sync` kick of the source coordinator (`CloudKitCoordinatorRegistry.shared.existingCoordinator(forAlbumID:)`) makes the items disappear from the source grid immediately.

This path goes through `FileMoveHandler` with the floating pill — no overlay, no checkpoint — because it is metadata-only and completes in seconds.

Live Photos: both component records are reassigned before either is confirmed. An item still in the upload queue is not reassignable; it fails with a retryable error so the counts tell the user.

### The coordinator's moved-away rule

When `CloudKitSyncCoordinator.performSync` processes a changed record whose `albumID` differs from the coordinator's own, but whose `mediaID` is in this album's index, it treats the record as gone: removes the component from the index, evicts the cache entry, drops the size sidecar contribution, and emits a buffered delete event. This is how CloudKit-to-CloudKit moves propagate to every device through the ordinary change feed — no tombstones needed.

---

# Renaming a CloudKit album

A rename changes no identity. The `albumID` is minted once and never derived from the name, so the record name, the media join key, the blob cache folder, the index, the sidecars and the change token all stay where they are. The name is a field: `encName` in `album.json` and on the `EncAlbum` record.

`AlbumManager.renameAlbum(album:to:)` handles both storages synchronously. For a CloudKit album it validates the name, throws `.albumExists` if any other album on this device already has it (`albumNamed(_:otherThan:)`, hidden albums and both storages included), re-encrypts the name under the album key, and writes the new `encName` to `album.json` with `dirty = true` (`updateCloudKitAlbumMarker`). It then updates `currentAlbum`, broadcasts `.albumRenamed`, and saves the record in the background. A successful save clears `dirty`; a failed one (offline) leaves it, and the reconciler pushes it on its next pass.

Other devices get the changed `EncAlbum` on the change feed. `CloudKitAlbumReconciler` rewrites their `album.json` in place when `encName`, the hidden flag or the cover differ, unless their own marker is dirty, in which case their pending change is pushed over the record. Conflicts are last writer wins. Nothing is deleted, adopted or re-downloaded.

# Renaming an album with an unfinished move

A move's plan names its albums by endpoint, and plans are filed under their source album's id. A CloudKit album's id is its `albumID`, so renaming it touches no plan. A local album's id is `"<name>_local"`, so renaming it would orphan every plan that names it: no banner, no auto-resume, and an album-scope move re-planned under the new name would find no server album with that name and mint a second one.

So `AlbumManager.renameAlbum` carries the plans across a local rename (`MigrationPlanStore.carryPlans(acrossRenameOf:to:otherAlbums:)`):

- The album's own plans, both scopes, move to the directory for its new id with their source endpoint renamed. An album-scope plan names the album at both ends, so its destination is renamed too, and its `cloudKitAlbumID` is kept, so the resume lands in the album the move started in. If the destination already has an `album.json` (the reconciler adopts the move's `EncAlbum` from the server mid-move, and finalize keeps an existing marker), the marker's `encName` is rewritten to the new name and the record pushed; otherwise the resumed run saves the record under the new name.
- Other albums' plans that move items into it (a move back to this device) get their destination renamed in place.
- A rename keeps the key, so each plan is decrypted and re-encrypted with the key it was written with. A plan that does not read is left where it is.

A rename is refused with `AlbumError.moveInProgress` while a run holds the album (`CloudKitMigrationManager.isActive(albumID:)`, readable from any thread), rather than rewriting a plan under a live run. The album screen shows it as "This album can't be renamed while items are moving."

A plan's persisted `albumName` for a CloudKit endpoint goes stale when that album is renamed, here or on another device. It is display data only: the media-move banner and the progress task name show `MigrationEndpoint.displayName(among:)`, which finds the live album by `cloudKitAlbumID`.
