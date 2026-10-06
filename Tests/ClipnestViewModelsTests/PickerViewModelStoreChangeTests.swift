// PickerViewModelStoreChangeTests.swift
//
// T-RT2: pins the fix for the actual reported bug — "Clear All History…"
// (or ANY other call site sharing the same injected `ClipStore`) emptied
// the store but left an already-open picker showing stale rows until it was
// closed and reopened. Root cause: Settings called `clipStore.clearHistory()`
// directly, and `PickerViewModel` had no way to learn a mutation it didn't
// itself make had happened.
//
// These tests construct the picker exactly like a real composition root
// does — `NotifyingClipStore(wrapping: InMemoryClipStore())`, its `.changes`
// broadcaster handed to `PickerViewModel` as `storeChanges:` — then mutate
// the store from OUTSIDE the view model entirely (a bare `clipStore.
// clearHistory()`/`enforceRetention(cap:)` call, standing in for Settings'
// button/background retention), never through `PickerViewModel` itself, and
// assert `rows` updates with NO `willShow()`/close-reopen call in between.

import ClipnestCore
import Foundation
import Testing

@testable import ClipnestViewModels

@MainActor
@Suite("PickerViewModel reacts to external ClipStore changes (T-RT2)")
struct PickerViewModelStoreChangeTests {

  @Test(
    "Clearing the store from OUTSIDE the view model empties an already-open picker's rows, without a close/reopen"
  )
  func externalClearHistoryEmptiesAnOpenPicker() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let notifyingStore = NotifyingClipStore(wrapping: InMemoryClipStore(blobStore: blobStore))
    _ = try await notifyingStore.insertOrBumpDuplicate(makeClipItem(previewText: "one"))
    _ = try await notifyingStore.insertOrBumpDuplicate(makeClipItem(previewText: "two"))
    _ = try await notifyingStore.insertOrBumpDuplicate(makeClipItem(previewText: "three"))

    let viewModel = makeTestPickerViewModel(
      clipStore: notifyingStore, blobStore: blobStore, storeChanges: notifyingStore.changes)
    viewModel.willShow()
    await waitUntil { viewModel.rows.count == 3 }
    #expect(viewModel.rows.count == 3)

    // The bug's exact reported scenario: something OTHER than this picker
    // (Settings' "Clear All History…") calls `clearHistory()` directly on
    // the SAME store instance the picker was constructed with.
    try await notifyingStore.clearHistory()

    await waitUntil { viewModel.rows.isEmpty }
    #expect(viewModel.rows.isEmpty)
  }

  @Test(
    "A hidden picker does not bother re-querying on an external clearHistory — it refreshes on the next willShow() instead"
  )
  func externalClearHistoryOnAHiddenPickerDoesNotEagerlyRequery() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let notifyingStore = NotifyingClipStore(wrapping: InMemoryClipStore(blobStore: blobStore))
    _ = try await notifyingStore.insertOrBumpDuplicate(makeClipItem(previewText: "one"))

    let viewModel = makeTestPickerViewModel(
      clipStore: notifyingStore, blobStore: blobStore, storeChanges: notifyingStore.changes)
    // Never called `willShow()` — the picker is hidden, matching a real
    // app's state before the user ever opens it.

    try await notifyingStore.clearHistory()
    // Give the (deliberately not gated on visibility from the caller's
    // side) subscription a moment to have fired, if it were going to.
    await Task.yield()

    #expect(viewModel.rows.isEmpty)  // still the initial, never-queried value

    viewModel.willShow()
    await waitUntil { viewModel.rows.isEmpty && !(viewModel.isSearching) }
    #expect(viewModel.rows.isEmpty)
  }

  @Test(
    "enforceRetention trimming the store from OUTSIDE the view model refreshes an already-open picker's rows"
  )
  func externalRetentionRefreshesAnOpenPicker() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let notifyingStore = NotifyingClipStore(wrapping: InMemoryClipStore(blobStore: blobStore))
    let older = try await notifyingStore.insertOrBumpDuplicate(
      makeClipItem(previewText: "older"))
    let newer = try await notifyingStore.insertOrBumpDuplicate(
      makeClipItem(previewText: "newer"))

    let viewModel = makeTestPickerViewModel(
      clipStore: notifyingStore, blobStore: blobStore, storeChanges: notifyingStore.changes)
    viewModel.willShow()
    await waitUntil { viewModel.rows.count == 2 }

    // Background retention (`AppEnvironment`/`LinuxAppEnvironment
    // .scheduleRetentionEnforcement()`), never routed through the picker.
    try await notifyingStore.enforceRetention(cap: .maxCount(1))

    await waitUntil { viewModel.rows.count == 1 }
    #expect(viewModel.rows.map(\.id) == [newer.id])
    _ = older
  }

  @Test(
    "A live capture (insert) is NOT double-handled by the external-change subscription — handleNewCapture's own path still governs it"
  )
  func insertIsNotDoubleHandled() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let notifyingStore = NotifyingClipStore(wrapping: InMemoryClipStore(blobStore: blobStore))
    _ = try await notifyingStore.insertOrBumpDuplicate(makeClipItem(previewText: "seed"))

    let viewModel = makeTestPickerViewModel(
      clipStore: notifyingStore, blobStore: blobStore, storeChanges: notifyingStore.changes)
    viewModel.willShow()
    // Waits for a non-trivial condition (1, not the initial-value 0) so this
    // genuinely proves the FIRST query has landed before the insert below —
    // otherwise a still-in-flight first query could race the insert and
    // pick up the new item on its own, independent of anything this test is
    // actually trying to prove.
    await waitUntil { viewModel.rows.count == 1 }

    // Inserting directly through the store (bypassing `ClipboardMonitor
    // .onCapture`/`handleNewCapture()` entirely) proves the picker doesn't
    // ALSO react to `.inserted` via the external-change subscription this
    // task adds — it's deliberately ignored there (see `PickerViewModel
    // .handleExternalStoreChange(_:)`'s doc comment); real capture flows
    // through `onCapture` -> `handleNewCapture()` instead, unchanged by
    // this task. If `.inserted` were mishandled here too, `rows` would grow
    // to 2 on its own with no further trigger.
    _ = try await notifyingStore.insertOrBumpDuplicate(makeClipItem(previewText: "uncaptured"))
    await Task.yield()
    await Task.yield()

    #expect(viewModel.rows.count == 1)
  }
}
