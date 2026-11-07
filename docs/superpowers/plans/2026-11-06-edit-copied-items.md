# Edit Copied Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users edit text, rich text, and link history items (and the OCR text of images) in place through a small WYSIWYG popup, on macOS and Linux (GTK), with save replacing the original entry.

**Architecture:** A new `ClipStore.updateContent` replaces an item's content fields in all three stores (merging on a `contentHash` collision). Hash/preview/size/kind derivation is extracted from `PasteboardReader` into one shared helper so an edited item equals a fresh capture. A `@MainActor ItemEditCoordinator` in `ClipnestViewModels` owns the save flow (clipboard check, off-main hashing and blob I/O, store update, conditional clipboard rewrite). Each platform supplies its own editor (NSTextView / GtkTextView) and its own rich-text codec; everything else is shared.

**Tech Stack:** Swift 6 (strict concurrency in Core), Swift Testing, SwiftUI + AppKit (`NSTextView`), SwiftData, SQLite (`ClipnestSQLite`), GTK4 via `CGtk4`. No new third-party dependency.

**Spec:** `docs/superpowers/specs/2026-11-06-edit-copied-items-design.md`

## Global Constraints

- Read `.claude/coding-standards.md` Non-negotiables first. Cross-platform seams are **required initializer parameters, never defaulted closures** (`presentSnippetEditor`'s `{ _ in }` default is the anti-pattern). GTK signal handlers must not re-enter themselves; defer window handoffs with `g_idle_add_full`. Never report an unconfirmed outcome as confirmed (clipboard write has a third state). No magic strings: user-facing copy lives in `ItemEditStrings` (Task 3).
- Exact copy: warning `Some formatting in this item can't be kept.`; gone-item message `This item no longer exists.`; actions `Edit` and `Edit Recognized Text`.
- **No edit affordance of any kind** (button, menu entry, shortcut, accessibility action) for `.file`, or for `.image` without non-empty `ocrText`. The rule lives only in the `ClipItem` predicates (Task 1).
- Save replaces the entry: `createdAt`, `pinned`, `pinnedAt`, source-app fields, `ocrText` are unchanged (except the merge rule: pinned if either was pinned, keep the earlier `pinnedAt`). Cancel changes nothing.
- Only NSPasteboard / clipboard reads happen on main; hashing, RTF/HTML serialization, and blob I/O run off-main (`Task.detached(priority: .utility)`).
- No new SwiftData attributes. If one proves necessary it must be optional/defaulted with a backfill (it should not be).
- macOS deployment target 14.0; no new imports outside the coding-standards dependency list.
- **Git:** agents `git add` their files (Stage steps); never `git commit` or `git push`.
- Docs are updated in the same task that changes the behaviour (Task 11 only consolidates README/user docs).
- Test commands used below. macOS: `swift test --filter <Suite>`; lint: `swift format lint --recursive --strict Sources Tests` and `swift format lint --recursive --strict ClipnestApp/Sources`. Linux (on a Linux host `make test-linux`; `make test-linux` refuses to run on macOS, so from macOS use): `docker run --rm -v "$PWD":/src -v clipnest-scratch:/src/.build -w /src clipnest-build:latest swift test --filter <Suite>`. Full suites: `make test` (host-appropriate) and `make lint`.

## Review Focus

Failure modes the spec implies that no acceptance criterion exercises, most likely first. Each has its pinning test in the named task.

1. Merge where the edited rich text collides with another item whose blob is the **same file** (rich `contentHash` == blob hash, so `blobPath` is identical): deleting the merged-away item's blob would delete the survivor's blob. Pinned in Task 2.
2. Hostile or malformed clipboard HTML on Linux (unclosed tags, `<<<<`, 10k-deep nesting, `&#99999999999;`, `&#0;`, NUL bytes, invalid UTF-8, multi-MB input): the editor must open with plain text and the warning, never crash or hang. Pinned in Task 8.
3. A Linux rich-text item whose bundle has no `text/html` (RTF-only), a legacy flat-HTML blob, or a missing blob: editor opens with the plain preview text, warning shown (RTF-only/legacy-unparseable) or none (no blob), no blank editor. Pinned in Task 8 and Task 3.
4. Whitespace/newline-only edits and edits with trailing newline: Save disabled for whitespace-only; for `"abc\n"` the hash comes from the raw string while `previewText` is trimmed, exactly like capture. Pinned in Tasks 1 and 3.
5. Item deleted/evicted while the popup is open: `itemNoLongerExists`, nothing re-inserted, no orphan blob left behind. Pinned in Task 3 (also: saving with unchanged content neither merges the item with itself nor corrupts it; Task 2).

---

## File Structure

Create (Core): `Sources/ClipnestCore/Clipboard/LinkDetection.swift`, `Sources/ClipnestCore/Clipboard/ClipContentDerivation.swift`, `Sources/ClipnestCore/Store/ClipContentUpdate.swift`, `Sources/ClipnestCore/RichText/StyledRun.swift`, `Sources/ClipnestCore/RichText/HTMLStyledRunCodec.swift`, `Sources/ClipnestCore/Platform/macOS/MacEditableRichText.swift`.
Create (ViewModels): `Sources/ClipnestViewModels/UI/Picker/ItemEdit/{ItemEditStrings,ItemEditKindResolver,ItemEditCoordinator,ItemEditTypes}.swift`.
Create (macOS app): `ClipnestApp/Sources/UI/Picker/{ItemEditorWindow,ItemEditorView,RichTextEditorView}.swift`.
Create (Linux): `Sources/ClipnestPlatformLinux/Clipboard/LinuxEditableRichText.swift`, `Sources/ClipnestGTK/Window/{ItemEditorWindow,ItemEditorWindow+RichText}.swift`.
Modify: `ClipItemOCR.swift`, `PasteboardReader.swift`, `BlobStore.swift`, `ClipStore.swift`, `InMemoryClipStore.swift`, `NotifyingClipStore.swift`, `SwiftDataClipStore.swift`, `SQLiteClipStore.swift`, `PickerViewModel.swift` (+ `PickerViewModel+Edit.swift` new), `ItemRow.swift`, `PickerView.swift`, `AppEnvironment.swift`, `LinuxAppEnvironment.swift`, `ItemRowActionContent.swift`, `PickerWindow+RowActions.swift`, docs.

---

### Task 1: Core primitives (predicates, derivation, link detection, blob helpers)

**Files:**
- Modify: `Sources/ClipnestCore/Model/ClipItemOCR.swift` (add next to `supportsSaveAsSnippet`)
- Create: `Sources/ClipnestCore/Clipboard/LinkDetection.swift`, `Sources/ClipnestCore/Clipboard/ClipContentDerivation.swift`
- Modify: `Sources/ClipnestCore/Clipboard/PasteboardReader.swift:512-532` (`readPlainText`, `isLink`, and `readRichText` call the new helpers), `Sources/ClipnestCore/Store/BlobStore.swift`
- Test: `Tests/ClipnestCoreTests/ClipItemEditingTests.swift`, `Tests/ClipnestCoreTests/ClipContentDerivationTests.swift`, existing `PasteboardReaderTests.swift` must stay green unchanged.

**Interfaces:**
- Produces:
  - `ClipItem.supportsContentEdit: Bool` (`kind` is `.text`, `.richText`, or `.link`) and `ClipItem.supportsRecognizedTextEdit: Bool` (== `hasRecognizedText`).
  - `public enum LinkDetection { public static func isLink(_ text: String) -> Bool }` (body and `validLinkSchemes` moved verbatim from `PasteboardReader`).
  - `public struct DerivedClipContent: Sendable, Equatable { kind: ItemKind; previewText: String; contentHash: String; byteSize: Int }`
  - `public enum ClipContentDerivation { static func plainText(_ text: String) -> DerivedClipContent; static func richText(blob: Data, plainText: String) -> DerivedClipContent }`
  - `BlobStore.blobPath(for data: Data) -> String` (static; `write(_:)` now calls it) and `BlobStore.contains(blobPath: String) -> Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
// ClipItemEditingTests
@Test func contentEditSupportedForTextRichTextLinkOnly()      // .text/.richText/.link true; .image/.file false
@Test func recognizedTextEditNeedsImageWithNonEmptyOCR()      // image+"hi" true; image+nil, image+"" , text+"x" false
@Test func fileAndOcrlessImageHaveNoEditAffordance()          // both predicates false for .file and image(ocrText nil)

// ClipContentDerivationTests
@Test func plainTextTrimsPreviewButHashesRawBytes() {
  let d = ClipContentDerivation.plainText("abc\n")
  #expect(d.previewText == "abc")
  #expect(d.contentHash == BlobStore.contentHash(of: Data("abc\n".utf8)))
  #expect(d.byteSize == 4 && d.kind == .text)
}
@Test func singleURLBecomesLink()  // plainText("https://example.com") -> .link; "see https://example.com" -> .text
@Test func richTextHashesBlobAndUsesBlobSize()  // hash == contentHash(of: blob), byteSize == blob.count, kind .richText
@Test func blobPathForDataMatchesWrite()  // BlobStore.blobPath(for: d) == (try store.write(d)); contains(...) true after write, false before
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ClipContentDerivationTests`
Expected: FAIL (compile error, `ClipContentDerivation` not defined).

- [ ] **Step 3: Implement**
  - `ClipItemOCR.swift`: the two predicates with doc comments naming their call sites (Tasks 4, 7, 10) and the "no affordance on files/OCR-less images" rule.
  - `LinkDetection.swift`: move `isLink` + `validLinkSchemes`; `PasteboardReader.readPlainText` calls it.
  - `ClipContentDerivation.swift`: `plainText` = trim preview, `kind = LinkDetection.isLink(preview) ? .link : .text`, hash/size from the **untrimmed** UTF-8 bytes (what capture does today); `richText` = trimmed preview, hash of `blob`, `byteSize = blob.count`. `PasteboardReader.readPlainText`/`readRichText` build their `Classification` from `DerivedClipContent` (the `"Rich Text"` placeholder and `fallbackPlainText` logic stay in the reader).
  - `BlobStore`: extract the `"\(blobsDirectoryName)/\(contentHash)"` expression into `static func blobPath(for:)`; add `contains(blobPath:)` using `fileManager.fileExists`.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter ClipContentDerivationTests && swift test --filter ClipItemEditingTests && swift test --filter PasteboardReaderTests`
Expected: all PASS (existing reader tests prove capture is unchanged).

- [ ] **Step 5: Lint, docs, stage**
Run `swift format lint --recursive --strict Sources Tests` (zero findings). Update the `ClipItem.contentHash` doc comment in `ClipItem.swift` to say edits recompute it through `ClipContentDerivation`.
```bash
git add Sources/ClipnestCore Tests/ClipnestCoreTests/ClipItemEditingTests.swift Tests/ClipnestCoreTests/ClipContentDerivationTests.swift
```

---

### Task 2: Store layer — `updateContent` in every `ClipStore`

**Files:**
- Create: `Sources/ClipnestCore/Store/ClipContentUpdate.swift`
- Modify: `Sources/ClipnestCore/Store/ClipStore.swift`, `InMemoryClipStore.swift`, `NotifyingClipStore.swift`, `Sources/ClipnestCore/Platform/macOS/SwiftDataClipStore.swift`, `Sources/ClipnestSQLite/ClipItems/SQLiteClipStore.swift`
- Modify (test conformer): `Tests/ClipnestCoreTests/ClipboardMonitorTests.swift:84` (`ThrowingClipStore`)
- Test: `Tests/ClipnestCoreTests/ClipStoreContractTests.swift` (scenarios), wired in `ClipStoreTests.swift`, `SwiftDataClipStoreTests.swift`, `SQLiteClipStoreTests.swift`; `NotifyingClipStore` test in the existing notifying-store test file (grep `NotifyingClipStore` under `Tests/`).

**Interfaces:**
- Consumes: `DerivedClipContent` (Task 1).
- Produces:
```swift
public struct ClipContentUpdate: Sendable, Equatable {
  public let kind: ItemKind; public let previewText: String
  public let contentHash: String; public let byteSize: Int; public let blobPath: String?
  public init(derived: DerivedClipContent, blobPath: String?)
}
public struct ClipContentUpdateResult: Sendable, Equatable {
  public let item: ClipItem          // the surviving, updated item
  public let mergedAwayID: UUID?     // non-nil when another item with the same hash was deleted
}
// ClipStore:
func updateContent(_ id: UUID, with update: ClipContentUpdate) async throws -> ClipContentUpdateResult
// shared cleanup, next to deleteBlobs(for:using:):
public func deleteOrphanedBlobs(candidates: [String?], stillReferenced: Set<String>, using: BlobStore) throws
```
Semantics (all stores): throws `ClipStoreError.notFound` for an unknown id. Replaces `kind/previewText/contentHash/byteSize/blobPath`; keeps everything else. If a **different** item already has `update.contentHash`: delete it, set survivor `pinned = a || b` and `pinnedAt = min(non-nil pinnedAt)`, return its id as `mergedAwayID`. An update whose hash equals the item's own hash is an in-place rewrite, never a self-merge. Search indexes (`normalizedText` in SwiftData; `normalized_text` in SQLite via `ClipItemNormalization.computeNormalizedText`) are recomputed from the new `previewText` plus the kept `ocrText`. Blob cleanup runs **after** the store write succeeds: candidates = old `blobPath` of the edited item and `blobPath` of the merged-away item; a candidate is deleted only if it is not referenced by any remaining item (survivor included). SQLite: delete the other row first, then update, in one `connection.withTransaction` (the `UNIQUE` index on `content_hash`, `ClipItemsSchema.swift:91`). SwiftData: delete + update, one `save()`. `NotifyingClipStore` broadcasts `.updated(id)` and, when `mergedAwayID != nil`, `.deleted(mergedAwayID)` — only after success.

- [ ] **Step 1: Write the failing contract scenarios** in `ClipStoreContractTests` (blob scenarios use the existing `BlobStore`-receiving factory shape; each is wired into all three store test files):

```swift
static func updateContentReplacesFieldsAndKeepsPositionPinAndMetadata(makeStore:)
  // item pinned, createdAt T, ocrText "x", source app set -> after update: new kind/preview/hash/size/blobPath;
  // createdAt, pinned, pinnedAt, sourceAppName, sourceBundleID, ocrText unchanged; fetchAll().count unchanged
static func updateContentUnknownIDThrowsNotFound(makeStore:)       // #expect(throws: ClipStoreError.notFound)
static func updateContentMakesNewTextSearchableAndOldTextNot(makeStore:)
  // query(text:"new") finds it, query(text:"old") returns []
static func updateContentMergesOnHashCollision(makeStore:)
  // A(pinned,pinnedAt P2) edited to B's hash where B pinned at P1 < P2: count 2->1, survivor.id == A.id,
  // survivor.pinned, survivor.pinnedAt == P1, result.mergedAwayID == B.id
static func updateContentMergeOfUnpinnedPairStaysUnpinned(makeStore:)
static func updateContentWithUnchangedHashDoesNotMergeWithSelf(makeStore:)  // count unchanged, mergedAwayID == nil
static func updateContentDeletesOldBlobWhenUnreferenced(makeStore:)         // old blob file gone, new blob file present
static func updateContentKeepsOldBlobWhenAnotherItemReferencesIt(makeStore:)
static func updateContentMergeDoesNotDeleteSharedBlob(makeStore:)
  // edited and merged-away item end with the SAME blobPath: file still exists afterwards
```
Plus `NotifyingClipStore`: `updateContentBroadcastsUpdatedThenDeletedOnMerge`, and `updateContentFailureBroadcastsNothing`.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ClipStoreTests`
Expected: FAIL (compile error: `updateContent` not a member of `ClipStore`).

- [ ] **Step 3: Implement** `ClipContentUpdate.swift`, the protocol method (doc comment states the semantics above and that `Paster`/UI never call it directly), `deleteOrphanedBlobs` (reuses `deleteBlobs` collect-then-throw policy), then the four conformances (`InMemoryClipStore`, `SwiftDataClipStore`, `SQLiteClipStore`, `NotifyingClipStore`) and the `ThrowingClipStore` test stub (throws its configured error). "Still referenced" is a per-store query: in-memory scan, SwiftData `fetchCount` on `blobPath`, SQLite `SELECT COUNT(*) ... WHERE blob_path = ?`. Update the `ClipStore` header doc comment and `NotifyingClipStore` doc comment (mutation list).

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter ClipStoreTests && swift test --filter SwiftDataClipStoreTests && swift test --filter SQLiteClipStoreTests && swift test --filter ClipboardMonitorTests`
Expected: PASS for all three stores (same scenarios, identical results). Then run the new scenarios against the unmodified code path by temporarily commenting out the merge branch in `InMemoryClipStore` and confirm `updateContentMergesOnHashCollision` goes red (restore after).
Linux: `docker run --rm -v "$PWD":/src -v clipnest-scratch:/src/.build -w /src clipnest-build:latest swift test --filter SQLiteClipStoreTests` expects PASS.

- [ ] **Step 5: Lint and stage**
```bash
swift format lint --recursive --strict Sources Tests
git add Sources/ClipnestCore Sources/ClipnestSQLite Tests/ClipnestCoreTests
```

---

### Task 3: Shared edit logic in `ClipnestViewModels` (strings, kind resolution, validation, coordinator)

**Files:**
- Create: `Sources/ClipnestViewModels/UI/Picker/ItemEdit/ItemEditStrings.swift`, `ItemEditKindResolver.swift`, `ItemEditTypes.swift`, `ItemEditCoordinator.swift`
- Test: `Tests/ClipnestViewModelsTests/ItemEditKindResolverTests.swift`, `ItemEditCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 1 (`ClipContentDerivation`, `LinkDetection`, `BlobStore.blobPath(for:)`, `contains`), Task 2 (`updateContent`), existing `PasteboardReader.pullRawPayload(from:)` / `classify(_:)` / `RawPayload`, `PasteboardWriting.writeString/writeRichText/changeCount`.
- Produces:
```swift
public enum ItemEditStrings {            // all user-facing copy, both platforms
  static let lossyWarning = "Some formatting in this item can't be kept."
  static let itemGone = "This item no longer exists."
  static let saveFailed, editTitle, editRecognizedTextTitle, save, cancel, saveAnyway, goBack: String
  static let editActionLabel = "Edit"; static let editRecognizedTextActionLabel = "Edit Recognized Text"
}
public enum ItemEditMode: Equatable, Sendable { case content(ClipItem), recognizedText(ClipItem) }
public struct ItemEditSource: Sendable, Equatable { public let plainText: String; public let richBlob: Data? }
public struct EditorOutput: Sendable, Equatable {   // what a platform editor hands back
  public let plainText: String; public let hasFormatting: Bool; public let richBlob: Data
}
public enum ClipboardSyncResult: Sendable, Equatable { case notOnClipboard, written, writeUnconfirmed }
public enum ItemEditOutcome: Sendable, Equatable {
  case saved(ClipItem, clipboard: ClipboardSyncResult)
  case itemNoLongerExists
  case failed(message: String)
}
public enum ItemEditKindResolver {
  public static func resolve(originalKind: ItemKind, plainText: String, hasFormatting: Bool) -> ItemKind
}
public enum ItemEditValidation { public static func canSave(plainText: String) -> Bool }  // trimmed non-empty
@MainActor public final class ItemEditCoordinator {
  public init(clipStore: any ClipStore, blobStore: BlobStore, pasteboard: any PasteboardWriting,
              pasteboardReader: PasteboardReader,
              readClipboardPayload: @escaping @MainActor () -> PasteboardReader.RawPayload?,
              suppressOwnPasteboardWrite: @escaping @MainActor (Int) -> Void,
              writeConfirmationTimeout: Duration)          // all required, no defaults
  public func loadSource(for item: ClipItem) async -> ItemEditSource
  public func saveContent(of item: ClipItem, output: EditorOutput) async -> ItemEditOutcome
  public func saveRecognizedText(of item: ClipItem, text: String) async -> ItemEditOutcome
}
```
Kind rules: `originalKind == .richText` -> `.richText` always (spec "stays richText"); else `hasFormatting` -> `.richText`; else `LinkDetection.isLink(trimmed) ? .link : .text` (same check as capture, so a plain-text item edited into a lone URL becomes `.link`; chosen so capture and edit never disagree).

- [ ] **Step 1: Write the failing tests**

```swift
// ItemEditKindResolverTests
@Test func plainTextWithoutFormattingStaysText()                    // (.text,"hello",false) -> .text
@Test func anyFormattingMakesRichText()                             // (.text,"hello",true) -> .richText
@Test func linkEditedToNonURLBecomesText()                          // (.link,"not a url",false) -> .text
@Test func linkStaysLinkWhileSingleURLUnformatted()                 // (.link,"https://a.b",false) -> .link
@Test func formattedLinkBecomesRichText()                           // (.link,"https://a.b",true) -> .richText
@Test func richTextWithAllFormattingRemovedStaysRichText()          // (.richText,"x",false) -> .richText
@Test func textEditedIntoLoneURLBecomesLinkLikeCapture()
@Test func whitespaceOnlyCannotSave()                               // "", "  \n\t" false; "a" true

// ItemEditCoordinatorTests (InMemoryClipStore over a temp BlobStore; fake PasteboardWriting; scripted RawPayload)
@Test func saveReplacesInPlaceWithoutNewEntry()                     // count unchanged, createdAt/pinned kept
@Test func plainEditWithBoldProducesRichTextItemWithBlob()          // kind .richText, blobPath == BlobStore.blobPath(for: blob)
@Test func editedItemEqualsFreshCaptureOfSameContent()              // updated hash/preview/size == PasteboardReader.classify(.plainText(s))
@Test func clipboardHoldingEditedItemIsRewrittenAndSuppressed()     // payload hash == item.contentHash -> writeRichText/writeString called, suppress(changeCount) called once, result .written
@Test func clipboardHoldingSomethingElseIsUntouched()               // zero writes, zero suppress calls, .notOnClipboard
@Test func clipboardChangedMidEditIsUntouched()                     // payload now Y (different hash) -> no write; item holds edited text
@Test func unconfirmedClipboardWriteReportsWriteUnconfirmed()       // fake changeCount never moves -> .writeUnconfirmed, still .saved
@Test func deletedItemYieldsItemNoLongerExistsAndWritesNothing()    // store.delete first; no blob file left, no store row, no pasteboard write
@Test func collidingEditMergesAndReportsSurvivor()                  // other item removed from store
@Test func loadSourceForRichTextWithMissingBlobFallsBackToPlain()   // blob nil, plainText == previewText
@Test func saveRecognizedTextChangesSearchAndLeavesImageBlob()      // query(text:) finds it; item.blobPath unchanged; pasteboard never written
@Test func hashingAndBlobWriteRunOffMainActor()                     // spy BlobStore-wrapping closure asserts !Thread.isMainThread (or Task-isolation check) during write
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ItemEditKindResolverTests`
Expected: FAIL (compile error).

- [ ] **Step 3: Implement.** Save flow of `saveContent`: (1) on main call `readClipboardPayload()` only; (2) inside one `Task.detached(priority: .utility)` compute `clipboardHash = payload.flatMap(reader.classify)?.contentHash`, `kind`, `DerivedClipContent`, and for `.richText` write the blob if `!blobStore.contains(blobPath:)` (remember whether it was created); (3) `clipStore.updateContent`; `ClipStoreError.notFound` -> delete the blob **only if this call created it**, return `.itemNoLongerExists`; any other error -> `.failed(ItemEditStrings.saveFailed)` (log metadata only, never content); (4) if `clipboardHash == item.contentHash` (the **pre-edit** hash) rewrite the clipboard on main with the same `PasteboardWriting` calls `copyRecognizedText` uses (`writeRichText(rtf: blob, plain: preview)` for `.richText`, else `writeString(preview, forType: .string)`), then poll `pasteboard.changeCount` against the pre-write value up to `writeConfirmationTimeout` (pattern: `PickerViewModel.confirmWrite`), call `suppressOwnPasteboardWrite(pasteboard.changeCount)`, and return `.written` or `.writeUnconfirmed`. `Paster.paste` is deliberately not used: it synthesizes a keystroke; there is no write-only `Paster` API. `loadSource` reads the blob in `Task.detached`.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter ItemEditKindResolverTests && swift test --filter ItemEditCoordinatorTests`
Expected: PASS. Run once against a coordinator with the pre-edit-hash check inverted to confirm `clipboardChangedMidEditIsUntouched` goes red.

- [ ] **Step 5: Lint, stage**
```bash
swift format lint --recursive --strict Sources Tests
git add Sources/ClipnestViewModels/UI/Picker/ItemEdit Tests/ClipnestViewModelsTests/ItemEditKindResolverTests.swift Tests/ClipnestViewModelsTests/ItemEditCoordinatorTests.swift
```

---

### Task 4: `PickerViewModel` integration (required presenter seam, gating, refresh)

**Files:**
- Modify: `Sources/ClipnestViewModels/UI/Picker/PickerViewModel.swift:586` (init), create `Sources/ClipnestViewModels/UI/Picker/PickerViewModel+Edit.swift`
- Modify (call sites, mechanical): every `PickerViewModel(` in `Tests/ClipnestViewModelsTests/*` (about 55, including `TestSupport/PickerViewModelFactory.swift`), `ClipnestApp/Sources/App/AppEnvironment.swift`, `Sources/ClipnestLinuxAppKit/App/LinuxAppEnvironment.swift`
- Test: `Tests/ClipnestViewModelsTests/PickerViewModelEditTests.swift`

**Interfaces:**
- Consumes: `ItemEditMode` (Task 3), `ClipItem.supportsContentEdit/supportsRecognizedTextEdit` (Task 1).
- Produces:
  - init parameter `presentItemEditor: @escaping @MainActor (ItemEditMode) -> Void` — **required, no default**, stored as `let`.
  - `public func presentEditForm(for item: ClipItem)` — `.image` with recognized text -> `.recognizedText(item)`; else `supportsContentEdit` -> `.content(item)`; else no call at all.
  - `public func reloadAfterEdit()` — `scheduleRowsQuery(.softReconcile, text: currentSearchText, debounced: false)` (unconditional; the picker stays open while the editor is up). `handleExternalStoreChange` keeps ignoring `.updated/.deleted` (own mutations refresh themselves; the editor is the mutator here, hence the explicit call).

- [ ] **Step 1: Write the failing tests**
```swift
@Test func editFormOpensContentModeForTextRichTextAndLink()   // 3 kinds -> exactly one call, .content(item)
@Test func editFormOpensRecognizedModeForImageWithOCR()       // .recognizedText(item)
@Test func editFormDoesNothingForFileAndOcrlessImage()        // call count 0 for .file, image(nil), image("")
@Test func reloadAfterEditRequeriesRowsKeepingPositionAndPin() // edit item via store, reload, row text updated, same index, pinned kept
```
- [ ] **Step 2: Run to verify they fail** — `swift test --filter PickerViewModelEditTests`; Expected: FAIL (compile error).
- [ ] **Step 3: Implement** the init parameter, `+Edit.swift`, and update every call site. Tests pass `presentItemEditor: { _ in }` written out. In `AppEnvironment`/`LinuxAppEnvironment` pass a **temporary** explicit `{ _ in /* replaced in Task 7 / Task 9 */ }` so the build stays green; Tasks 7 and 9 must delete it (Task 12 greps for it).
- [ ] **Step 4: Run** — `swift test --filter PickerViewModel` (every PickerViewModel suite) and `swift test --filter ShortcutHintsTests`; Expected: PASS, no regressions. Doc comment in `PickerViewModel.swift` top block gains one paragraph on the edit seam.
- [ ] **Step 5: Stage**
```bash
swift format lint --recursive --strict Sources Tests
git add Sources/ClipnestViewModels Tests/ClipnestViewModelsTests ClipnestApp/Sources/App/AppEnvironment.swift Sources/ClipnestLinuxAppKit/App/LinuxAppEnvironment.swift
```

---

### Task 5: macOS rich-text codec and format toggles (Core, testable via `swift test`)

**Files:**
- Create: `Sources/ClipnestCore/Platform/macOS/MacEditableRichText.swift` (`#if os(macOS)`, `import AppKit`)
- Test: `Tests/ClipnestCoreTests/MacEditableRichTextTests.swift` (`#if os(macOS)`)

**Interfaces:**
- Consumes: nothing new (RTF via `NSAttributedString`, same document type `MacRichTextFlattener` uses).
- Produces:
```swift
public enum MacEditableRichText {
  public enum FormatTrait: Sendable { case bold, italic, underline }
  public struct Loaded { public let attributed: NSAttributedString; public let isLossy: Bool }  // main-actor use only
  public static let defaultAttributes: [NSAttributedString.Key: Any]
  public static func load(rtf: Data?, plainText: String) -> Loaded
  public static func rtf(from attributed: NSAttributedString) -> Data?
  public static func hasFormatting(_ attributed: NSAttributedString) -> Bool
  public static func toggle(_ trait: FormatTrait, in storage: NSMutableAttributedString, range: NSRange)
}
```
`isLossy` = serialize the loaded string with `rtf(from:)`, reload, and the two attributed strings are not `isEqual(to:)`, OR any run carries an `NSTextAttachment`. `rtf == nil` -> not lossy, plain text with `defaultAttributes`. `toggle`: if every character in `range` already has the trait it is removed, otherwise added (via `NSFontManager` traits / `.underlineStyle`).

- [ ] **Step 1: Write the failing tests**
```swift
@Test func plainItemLoadsWithoutFormattingAndIsNotLossy()
@Test func boldRangeMakesHasFormattingTrue_removingItMakesItFalse()
@Test func toggleBoldTwiceOnSameRangeRestoresOriginal()
@Test func toggleUnderlineAndItalicApplyOnlyToRange()
@Test func rtfRoundTripPreservesBoldItalicUnderlineColor()      // rtf(from:) -> load -> same traits on same ranges
@Test func attachmentMarksItemLossy()
@Test func unreadableRTFFallsBackToPlainTextAndIsNotLossy()      // garbage Data -> plain text from previewText
@Test func untouchedRichItemRoundTripsLosslessly()               // fixture RTF with bold+italic only -> isLossy == false
```
- [ ] **Step 2: Run** — `swift test --filter MacEditableRichTextTests`; Expected: FAIL (compile error).
- [ ] **Step 3: Implement** per the interface; `hasFormatting` = any run differs from `defaultAttributes` in font traits/family/size, underline, strike, foreground color, link, or attachment.
- [ ] **Step 4: Run** — same command; Expected: PASS.
- [ ] **Step 5: Stage**
```bash
swift format lint --recursive --strict Sources Tests
git add Sources/ClipnestCore/Platform/macOS/MacEditableRichText.swift Tests/ClipnestCoreTests/MacEditableRichTextTests.swift
```

---

### Task 6: macOS editor popup (window, SwiftUI view, NSTextView wrapper, toolbar)

**Files:**
- Create: `ClipnestApp/Sources/UI/Picker/ItemEditorWindow.swift` (chrome modelled on `SnippetEditorWindow.swift`: 380x460, `positionRelativeToPicker`, `NSWindowDelegate`, `onClose`), `ItemEditorView.swift`, `RichTextEditorView.swift` (`NSViewRepresentable` over `NSScrollView` + `NSTextView`)
- Test: build + AX verification (UI stays thin per coding-standards; all logic is already unit-tested in Tasks 3 and 5)

**Interfaces:**
- Consumes: `ItemEditMode`, `ItemEditSource`, `EditorOutput`, `ItemEditOutcome`, `ItemEditStrings`, `ItemEditValidation`, `ItemEditCoordinator` (Task 3); `MacEditableRichText` (Task 5).
- Produces: `ItemEditorWindow.show(mode: ItemEditMode, source: ItemEditSource, pickerPanel: PickerPanel?, save: @escaping @MainActor (EditorOutput) async -> ItemEditOutcome, onSaved: @escaping @MainActor () -> Void, onClose: @escaping () -> Void)` and `init()`.

- [ ] **Step 1: Define behaviour checks** (written before code, verified in Step 4): content mode shows a formatting toolbar with exactly Bold / Italic / Underline buttons; recognized-text mode shows the same popup with the toolbar hidden and `NSTextView.isRichText = false`; Save disabled while `ItemEditValidation.canSave` is false; Cancel and window-close never call `save`.
- [ ] **Step 2: Implement.** On open: `source` -> `MacEditableRichText.load`; if `isLossy`, Save first shows an alert/confirmation with `ItemEditStrings.lossyWarning` and buttons `saveAnyway` / `goBack`; no warning when lossless. Save builds `EditorOutput(plainText: textView.string, hasFormatting: MacEditableRichText.hasFormatting(storage), richBlob: MacEditableRichText.rtf(from: storage) ?? Data())`, awaits `save`, and then: `.saved` -> `onSaved()` and close; `.itemNoLongerExists` -> inline red label `ItemEditStrings.itemGone`, window stays open, text still selectable/copyable; `.failed(message)` -> inline message, stays open. Toolbar buttons call `MacEditableRichText.toggle` on `selectedRange()` (and typing attributes when the selection is empty). Window title from `editTitle` / `editRecognizedTextTitle`.
- [ ] **Step 3: Build**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -project ClipnestApp.xcodeproj -scheme ClipnestApp -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`; `swift format lint --recursive --strict ClipnestApp/Sources` clean.
- [ ] **Step 4: Manual/AX verification is deferred to Task 7** (the window has no entry point until then); record in the Task 7 evidence.
- [ ] **Step 5: Stage**
```bash
git add ClipnestApp/Sources/UI/Picker/ItemEditorWindow.swift ClipnestApp/Sources/UI/Picker/ItemEditorView.swift ClipnestApp/Sources/UI/Picker/RichTextEditorView.swift
```

---

### Task 7: macOS entry points and wiring (row buttons, context menu, VoiceOver action, composition root)

**Files:**
- Modify: `ClipnestApp/Sources/UI/Picker/ItemRow.swift` (context menu ~144, `rowActions` ~166), `PickerView.swift` (pass `onEdit`), `ClipnestApp/Sources/App/AppEnvironment.swift` (replace Task 4 placeholder, build `ItemEditCoordinator`, own an `ItemEditorWindow`)
- Test: `ClipnestAppTests` if a row-gating test seam already exists (grep `ItemRow` under `ClipnestApp/Tests`); otherwise AX-tree verification below.

**Interfaces:**
- Consumes: `ClipItem.supportsContentEdit/supportsRecognizedTextEdit`, `ItemEditStrings.editActionLabel/editRecognizedTextActionLabel` (Tasks 1, 3), `PickerViewModel.presentEditForm(for:)` / `reloadAfterEdit()` / `presentItemEditor` (Task 4), `ItemEditorWindow` (Task 6).
- Produces: `ItemRow.onEdit: () -> Void` (new closure property, required initializer argument).

- [ ] **Step 1: Failing check.** Before wiring, assert (test or AX) that a text row has no Edit button; this is the red state.
- [ ] **Step 2: Implement.** In `ItemRow`: one computed `editLabel: String?` (`nil` when neither predicate holds) feeds all three surfaces: a pencil `ExpandingIconButton(systemName: "pencil", title: editLabel, action: onEdit)` placed between pin and save-as-snippet; a context-menu `Button(editLabel, systemImage: "pencil", action: onEdit)` after Pin; and `.accessibilityAction(named: Text(editLabel), onEdit)` (the row has no accessibility actions today; add only this one). `.file` rows and OCR-less images render none of the three. `AppEnvironment`: coordinator constructed with `readClipboardPayload: { reader.pullRawPayload(from: <the monitor's NSPasteboard reader>) }`, `suppressOwnPasteboardWrite: monitor.ignore(changeCount:)`, `writeConfirmationTimeout: .zero` (macOS `changeCount` moves synchronously); `viewModel.presentItemEditor` loads `coordinator.loadSource` then `ItemEditorWindow.show(... save: { coordinator.saveContent / saveRecognizedText }, onSaved: viewModel.reloadAfterEdit, onClose: re-key the panel + `refocusSearchField()` exactly like the snippet editor wiring at ~410)`. Delete the Task 4 placeholder.
- [ ] **Step 3: Build and sign**

Per project rules: `pkill -x Clipnest`; remove stale `Clipnest.app` from `/Applications` and every DerivedData/`build` path; build with `scripts/build.sh`; sign with the "Clipnest Local Dev" identity (Accessibility will not stick on an unsigned build).
Expected: build succeeds; `swift format lint --recursive --strict ClipnestApp/Sources` clean.
- [ ] **Step 4: Verify via the AX tree** (screencapture is TCC-blocked): launch, copy plain text `hello`, open the picker, confirm the row exposes an `Edit` button and `Edit` custom action; confirm file rows and OCR-less image rows expose neither; open the popup, bold a word, Save; confirm the same row (same index) now pastes with bold and the history count is unchanged. Walk acceptance criteria 1-9, 11, 12 on macOS and paste the observed output into `.claude/logs/<owner>.md`.
- [ ] **Step 5: Stage**
```bash
git add ClipnestApp/Sources
```

---

### Task 8: Linux styled-run codec and loader (pure Swift, no GTK)

**Files:**
- Create: `Sources/ClipnestCore/RichText/StyledRun.swift`, `Sources/ClipnestCore/RichText/HTMLStyledRunCodec.swift`, `Sources/ClipnestPlatformLinux/Clipboard/LinuxEditableRichText.swift`
- Test: `Tests/ClipnestCoreTests/HTMLStyledRunCodecTests.swift`, `Tests/ClipnestPlatformLinuxTests/LinuxEditableRichTextTests.swift`

**Interfaces:**
- Consumes: `LinuxRichTextBundle` (encode/decode), `LinuxClipboardConstants.richTextMimePriority`.
- Produces:
```swift
public struct StyledRun: Sendable, Equatable {
  public var text: String; public var bold, italic, underline: Bool
  public var colorHex: String?; public var fontFamily: String?; public var fontSizePt: Double?
  public var hasFormatting: Bool { get }
}
public struct EditableRichText: Sendable, Equatable { public var runs: [StyledRun]; public var isLossy: Bool }
public struct StyleSpan: Sendable, Equatable { public var start: Int; public var length: Int; public var run: StyledRun } // character offsets, text omitted
public enum StyledRunMapping {            // GTK buffer <-> runs, pure and unit-testable
  public static func flatten(_ runs: [StyledRun]) -> (text: String, spans: [StyleSpan])
  public static func runs(text: String, spans: [StyleSpan]) -> [StyledRun]
}
public struct ParsedStyledText: Sendable, Equatable { public let runs: [StyledRun]; public let hasUnsupportedContent: Bool }
public enum HTMLStyledRunCodec {
  public static let maxInputBytes = 1_000_000; public static let maxNestingDepth = 256
  public static func parse(html: String) -> ParsedStyledText      // total: never traps
  public static func html(from runs: [StyledRun]) -> String
}
public enum LinuxEditableRichText {
  public static func load(blob: Data?, plainText: String) -> EditableRichText
  public static func blob(from runs: [StyledRun]) -> Data           // LinuxRichTextBundle with ONE text/html representation
}
```
Supported subset: `b/strong`, `i/em`, `u`, `br`, `p/div` (newline separated), `span`/`font` carrying `color`, `font-family`, `font-size` (pt), bold/italic/underline CSS; entities `&amp; &lt; &gt; &quot; &#N; &#xN; &nbsp;`. Structural wrappers (`html head body meta title style script`) are transparent and not "lost content". `hasUnsupportedContent` is true for any other element (`table*`, `ul/ol/li`, `img`, `a`, `h1-h6`, `pre`, `code`, `sub/sup`, `s/del`, …) or CSS property outside the supported set. Input over `maxInputBytes` or nesting over `maxNestingDepth` -> `ParsedStyledText(runs: [], hasUnsupportedContent: true)` handled by `load` as plain fallback. `load`: `blob == nil` -> one plain run, not lossy; decode bundle, else treat bytes as legacy flat HTML; pick the first `text/html` representation by `richTextMimePriority`; no HTML representation or parse fallback -> one plain run from `plainText`, `isLossy = true`; otherwise `isLossy = hasUnsupportedContent || parse(html(from: runs)).runs != runs`. Saving regenerates the bundle from the editor (no stale RTF next to new HTML).

- [ ] **Step 1: Write the failing tests**
```swift
// HTMLStyledRunCodecTests
@Test func parsesBoldItalicUnderlineAndNestedCombinations()
@Test func parsesSpanColorFamilyAndPointSize()
@Test func decodesNamedAndNumericEntities()
@Test func brAndBlockElementsBecomeNewlines()
@Test func tableListImageAnchorMarkUnsupported()               // each alone -> hasUnsupportedContent true, text kept
@Test func headStyleScriptContentIsDroppedWithoutFlagging()
@Test func roundTripOfSupportedSubsetIsStable()                // parse(html(from: runs)).runs == runs
@Test func hostileInputsNeverCrash()                            // "<b><i>unclosed", "<<<<", "&#99999999999;", "&#0;", NUL bytes, 10_000-deep <b> nesting, 2 MB string
@Test func oversizedOrTooDeepInputIsFlaggedAndEmpty()
@Test func flattenAndRunsMappingRoundTripAcrossAdjacentStyles()
// LinuxEditableRichTextTests
@Test func nilBlobGivesPlainRunNotLossy()
@Test func cleanHtmlBundleLoadsFormattingNotLossy()
@Test func bundleWithTableIsLossy()
@Test func rtfOnlyBundleFallsBackToPlainAndIsLossy()
@Test func legacyFlatHtmlBlobIsReadAndSavedBackAsBundle()      // load(legacy) then LinuxRichTextBundle.decode(blob(from:)) has exactly one text/html rep
@Test func garbageBytesFallBackToPlainAndLossy()
@Test func savedBundleContainsOnlyRegeneratedHtml()            // no application/rtf rep survives
```
- [ ] **Step 2: Run** — `swift test --filter HTMLStyledRunCodecTests`; Expected: FAIL (compile error).
- [ ] **Step 3: Implement** a hand-written tokenizer (no `XMLParser`; clipboard HTML is not well-formed XML) with an explicit element stack bounded by `maxNestingDepth`. This code parses untrusted clipboard data: the reviewer's mandatory security pass applies (Task 12).
- [ ] **Step 4: Run**

`swift test --filter HTMLStyledRunCodecTests` (macOS) and `docker run --rm -v "$PWD":/src -v clipnest-scratch:/src/.build -w /src clipnest-build:latest swift test --filter LinuxEditableRichTextTests`
Expected: PASS on both.
- [ ] **Step 5: Stage**
```bash
swift format lint --recursive --strict Sources Tests
git add Sources/ClipnestCore/RichText Sources/ClipnestPlatformLinux/Clipboard/LinuxEditableRichText.swift Tests/ClipnestCoreTests/HTMLStyledRunCodecTests.swift Tests/ClipnestPlatformLinuxTests/LinuxEditableRichTextTests.swift
```

---

### Task 9: GTK editor popup and Linux wiring

**Files:**
- Create: `Sources/ClipnestGTK/Window/ItemEditorWindow.swift`, `Sources/ClipnestGTK/Window/ItemEditorWindow+RichText.swift`
- Modify: `Sources/ClipnestLinuxAppKit/App/LinuxAppEnvironment.swift` (replace the Task 4 placeholder; build the coordinator; own the window)
- Test: `Tests/ClipnestPlatformLinuxTests/ItemEditorWindowLogicTests.swift` for the pure helpers; the rest is Wayland/X11 manual verification.

**Interfaces:**
- Consumes: `EditableRichText`, `StyledRun`, `StyledRunMapping` (Task 8, via `ClipnestCore`), `ItemEditMode/EditorOutput/ItemEditOutcome/ItemEditStrings/ItemEditValidation` (Task 3), `LinuxEditableRichText` (Task 8, used only in `LinuxAppEnvironment`; `ClipnestGTK` does not depend on `ClipnestPlatformLinux`).
- Produces: `public final class ItemEditorWindow` with `public init(blobFromRuns: @escaping @Sendable ([StyledRun]) -> Data)` (required, no default) and `public func show(mode: ItemEditMode, initial: EditableRichText, save: @escaping @MainActor (EditorOutput) async -> ItemEditOutcome, onSaved: @escaping @MainActor () -> Void, onClose: @escaping () -> Void)`; internal pure helper `ItemEditorTagNames.name(for: StyledRun) -> [String]` (tags `b`, `i`, `u`, `color:#rrggbb`, `family:<name>`, `size:<pt>`; only `GtkTextTag` properties available in the GTK version the project targets: weight, style, underline, foreground-rgba, family, size-points).

- [ ] **Step 1: Write the failing tests** (pure only)
```swift
@Test func tagNamesForBoldItalicRunAreStableAndSorted()
@Test func plainRunHasNoTags()
@Test func bufferSpansMapBackToIdenticalRuns()           // StyledRunMapping via the window's helper
```
- [ ] **Step 2: Run** — `docker run ... swift test --filter ItemEditorWindowLogicTests`; Expected: FAIL (compile error).
- [ ] **Step 3: Implement** modelled on `SnippetEditorWindow.swift` (reuse its `defaultWidth/Height/formMargin/formSpacing` constants and trampoline pattern; do not copy them). `GtkTextView` + tag table; a toolbar of exactly Bold / Italic / Underline buttons toggling the tag on the current selection (no selection: no-op, documented limitation); recognized-text mode hides the toolbar and never creates tags. Save is enabled by `ItemEditValidation.canSave`. The lossy warning is an **inline** label (`ItemEditStrings.lossyWarning`) with `saveAnyway` / `goBack` buttons replacing the Save row (no modal dialog, avoiding Wayland popup quirks); `itemNoLongerExists` shows `ItemEditStrings.itemGone` inline and keeps the window open. Re-entrancy: `isClosing` guard on the close-request and `notify::is-active` paths, hide deferred with `g_idle_add_full`. Output: `EditorOutput(plainText:, hasFormatting: runs.contains { $0.hasFormatting }, richBlob: blobFromRuns(runs))`. Clipboard write must happen while the popup still has focus: close only after `save` returns. `LinuxAppEnvironment`: coordinator uses the existing `LinuxPasteboard` reader and `GTKClipboardWriting`, `suppressOwnPasteboardWrite` = the monitor's ignore, `writeConfirmationTimeout` = the same timeout carried by `PasteDismissOrdering.writeBeforeDismiss`; `presentItemEditor` loads the source (`coordinator.loadSource`), runs `LinuxEditableRichText.load`, shows the window with `blobFromRuns: LinuxEditableRichText.blob(from:)`. Delete the Task 4 placeholder.
- [ ] **Step 4: Run and verify**

`docker run --rm -v "$PWD":/src -v clipnest-scratch:/src/.build -w /src clipnest-build:latest swift test --filter ItemEditorWindowLogicTests` PASS; then `swift build` in the same container succeeds. Manual: under `mutter --headless --wayland` (per coding-standards) open the popup and confirm no `popup_done` loop and CPU stays idle; copy HTML with `<b>`, edit one word, Save, confirm clipboard pastes bold and no extra history entry. Paste observed output into the owner's log.
- [ ] **Step 5: Stage**
```bash
swift format lint --recursive --strict Sources Tests
git add Sources/ClipnestGTK Sources/ClipnestLinuxAppKit Tests/ClipnestPlatformLinuxTests
```

---

### Task 10: GTK row actions (buttons, context menu, dispatch)

**Files:**
- Modify: `Sources/ClipnestGTK/Window/ItemRowActionContent.swift`, `Sources/ClipnestGTK/Window/PickerWindow+RowActions.swift`
- Test: `Tests/ClipnestPlatformLinuxTests/GTKItemRowActionContentTests.swift` (extend)

**Interfaces:**
- Consumes: predicates (Task 1), `ItemEditStrings` labels and `PickerViewModel.presentEditForm(for:)` (Tasks 3, 4).
- Produces: `ItemRowAction.edit` and `ItemRowAction.editRecognizedText`; `gatedEntries(for:)` order: Pin/Unpin, Edit **or** Edit Recognized Text, [Save as Snippet], [Copy Recognized Text], Delete. Both new actions are button-eligible and appear in the context menu (the shared list keeps both surfaces in sync).

- [ ] **Step 1: Write the failing tests**
```swift
@Test func textRichTextAndLinkOfferEditInButtonsAndMenu()
@Test func imageWithOCROffersEditRecognizedTextAndCopyRecognizedText()
@Test func fileAndOcrlessImageOfferNoEditEntry()                // neither .edit nor .editRecognizedText anywhere
@Test func buttonsAndMenuShareTheSameEditEntry()                // same label and action in both lists
```
- [ ] **Step 2: Run** — `docker run ... swift test --filter GTKItemRowActionContentTests`; Expected: FAIL.
- [ ] **Step 3: Implement** the two cases and gating (reading only the Task 1 predicates), then the `performItemRowAction` branches calling `viewModel.presentEditForm(for: item)`. Update the file header comment (currently says three buttons plus one menu-only action). No keyboard shortcut is added (optional in the spec; none reassigned).
- [ ] **Step 4: Run** — same command; Expected: PASS.
- [ ] **Step 5: Stage**
```bash
swift format lint --recursive --strict Sources Tests
git add Sources/ClipnestGTK/Window Tests/ClipnestPlatformLinuxTests/GTKItemRowActionContentTests.swift
```

---

### Task 11: Documentation

**Files:**
- Modify: `README.md`, `docs/features.md`, `docs/API.md` (new `ClipStore.updateContent`, `ClipContentDerivation`, `LinkDetection`, `BlobStore.blobPath/contains`), `docs/API-ClipnestGTK.md` (editor window, new row actions), any user-facing site/docs page listing picker actions (grep `Save as Snippet` across `*.md`/`docs/`).
- Verify: in-code comments that assert limitations. Known candidates: `ItemRowActionContent.swift` header (Task 10), `ItemRow.swift:103-108` comment, `ClipItem.swift` `contentHash` comment, `ClipStore.swift` header. Run `grep -rniE "immutable|never edited|not editable|cannot be edited" Sources ClipnestApp docs README.md`.

- [ ] **Step 1:** Grep the code, not the docs, for current behaviour (per the doc-staleness rule) and list each doc location to change.
- [ ] **Step 2:** Update each doc in one voice: what Edit does, supported kinds, Edit Recognized Text, formatting warning, merge-on-duplicate, clipboard behaviour (rewritten only if the edited item is the current clipboard), Linux formatting subset (b/i/u, color, font family/size) and its toolbar limitation (selection required), GTK has no custom accessibility action (labelled buttons/menu entries instead).
- [ ] **Step 3: Verify**

Run: `grep -rn "Edit Recognized Text" README.md docs | head` shows the feature documented; the immutable-claim grep above returns no stale claim.
- [ ] **Step 4: Stage**
```bash
git add README.md docs
```

---

### Task 12: Cross-platform verification and review gates

**Files:** none (verification only; tester writes evidence in `.claude/logs/tester.md`, reviewer in `.claude/logs/reviewer.md`).

- [ ] **Step 1: Full suites and lint.** Run `make test` and `make lint` on macOS; on Linux `make test-linux`, or from macOS the docker command in Global Constraints with no `--filter`. Expected: zero failures, zero lint findings.
- [ ] **Step 2: No silent seams.** Run `grep -rn "presentItemEditor: { _ in" Sources ClipnestApp` — Expected: no matches outside `Tests/`.
- [ ] **Step 3: Acceptance walk.** Execute acceptance criteria 1-12 of the spec on macOS (AX tree) and Linux (headless mutter or the VNC image); criteria 5 (three clipboard scenarios) and 11 (merge, all three stores) are mandatory with pasted output.
- [ ] **Step 4: Security pass (hard trigger: user input / external I/O).** Reviewer reads `.claude/skills/security-review/SKILL.md` and `differential-review` and clears: HTML parser on untrusted clipboard data (Task 8), SQL binding in `SQLiteClipStore.updateContent`, no clipboard content in logs, no network APIs.
- [ ] **Step 5: Stage** any test artifacts the tester added; nothing is committed.

---

## Self-Review Notes

- **Spec coverage:** goals 1-5 -> Tasks 1-10; each decided-behaviour row maps to a task (kinds: 1/7/10; replace: 2; one editor: 6/9; position/pin: 2; clipboard: 3; kind after edit: 3; search: 2; empty: 3/6/9; lossy warning: 5/8 + 6/9; merge: 2). Calls made (OCR, entry points, hash/preview shared helper, "on clipboard" at save time, item gone, blob cleanup, `createdAt`, picker state) are in Tasks 1-4, 6, 7, 9, 10. Docs: Task 11. Acceptance criteria 1-12 mapped in Task 12.
- **Types:** `DerivedClipContent` (1) -> `ClipContentUpdate.init(derived:blobPath:)` (2) -> coordinator (3); `EditorOutput`, `ItemEditSource`, `ItemEditMode`, `ItemEditOutcome` defined once in Task 3 and consumed by 4, 6, 9; `EditableRichText`/`StyledRun` defined in Task 8, consumed in Task 9.
- **Proportion:** signatures, test names, and exact copy only; no function bodies.
