//
//  MediaIndexTestHooks.swift
//  EncameraCore
//
//  UI-test-only fault-injection points for the per-album media index.
//  All hooks default to inert values; the app sets them from launch
//  arguments inside `UITestMode.setupIfNeeded()` so production builds
//  are unaffected.
//

import Foundation

/// Test-only configuration that `InteractableMediaDiskAccess` and
/// `GalleryGridViewModel` consult so UI tests can deterministically
/// reproduce edge cases (failed materializations, smaller page sizes, etc.).
public enum MediaIndexTestHooks {
    /// When > 0, `materialize` returns `nil` for every entry whose
    /// `abs(id.hashValue) % stride == 0`. Lets a UI test seed an album,
    /// inject a deterministic failure rate, and assert that the gallery's
    /// pagination still fills each page.
    public static var failMaterializeStride: Int = 0

    /// When set, `GalleryGridViewModel` uses this value as its `pageSize`
    /// instead of the production default. Lets tests pick a window small
    /// enough to make page-fullness bugs obvious.
    public static var overridePageSize: Int? = nil

    /// Artificial per-page delay applied inside `mediaPage` so a test has a
    /// wide enough window to interleave UI actions (e.g. tap Delete while
    /// `loadAllPages` is still iterating). Inert when 0.
    public static var pageLoadDelayMs: Int = 0

    /// When > 0, `GalleryGridViewModel.loadAllPages` schedules a one-shot
    /// asynchronous "interrupt" N ms after it starts: it calls back into
    /// `enumerateMedia`, bumping `enumerateRequestID` and aborting the
    /// in-flight load. Lets a UI test exercise the sort/filter-change race
    /// without driving the production sort menu (which is hidden in
    /// selection mode). Inert when 0.
    public static var interruptLoadAllPagesAfterMs: Int = 0
}
