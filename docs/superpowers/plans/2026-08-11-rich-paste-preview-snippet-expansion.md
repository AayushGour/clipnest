# Rich Paste, Item Preview & Snippet Keyword Expansion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three features to Clipnest — paste-without-formatting (⌥Return), an item preview surface for images/long text/files, and snippet keyword expansion that replaces a selection in any app via the Accessibility API without touching the clipboard.

**Architecture:** Pure logic lands in `ClipnestCore` (unit-tested with `swift test`); macOS system integration (rich pasteboard write, AX read/replace, preview popover, global hotkey) lands in the `ClipnestApp` target behind protocols/mocks where testable and is manual-verified where it hits real AppKit/AX. No SwiftData schema change is made, so no migration is needed.

**Tech Stack:** Swift 6, SwiftUI + AppKit, SwiftData, Swift Testing, `KeyboardShortcuts` (the one approved third-party dep), XcodeGen.

**Reference spec:** `docs/superpowers/specs/2026-08-11-rich-paste-preview-snippet-expansion-design.md`

## Global Constraints

- **Language/UI:** Swift 6 + SwiftUI + AppKit interop. Minimum macOS **14.0**.
- **No SwiftData migration:** reuse existing `ClipItem.blobPath` and `Snippet.keyword` only. Do **not** add or change any `@Model` attribute. `#Index`/`#Unique` require macOS 15 and are banned (macOS 14 floor).
- **Dependencies:** exactly one third-party dependency (`KeyboardShortcuts`, `ClipnestApp`-only). Everything else is system frameworks.
- **Testing:** `ClipnestCore` logic via Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). Never touch the real `NSPasteboard`/AX from a test — use the injected fakes/mocks. Real AX/GUI/hotkey behavior is manual-verify only and must be flagged, never claimed as tested.
- **Privacy:** never log clipboard/snippet content — metadata only, via `os.Logger`.
- **Git:** agents run `git add` on finished files **only**. Never `git commit`/`git push` — the user authors every commit. (Each task's final step stages; it does not commit.)
- **Format/lint gate before staging any task:** `swift format lint --recursive --strict Sources Tests ClipnestApp/Sources` must be clean.
- **Core test command:** `swift test` (repo root). **App build command:** `cd ClipnestApp && xcodegen generate && xcodebuild -project ClipnestApp.xcodeproj -scheme ClipnestApp CODE_SIGNING_ALLOWED=NO build`.

---

## File Structure

**Feature A — Rich paste**
- Modify `Sources/ClipnestCore/Clipboard/PasteboardReader.swift` — store RTF bytes in `Classification.rawData`.
- Modify `Sources/ClipnestCore/Paste/Paster.swift` — `PasteContent.richText`, `PasteboardWriting.writeRichText`, `Paster.paste` case.
- Modify `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift` — `plainText` routing.
- Modify `ClipnestApp/Sources/UI/Picker/PickerView.swift` — ⌥Return key case + footer hint.
- Tests: `Tests/ClipnestCoreTests/PasteboardReaderTests.swift`, `Tests/ClipnestCoreTests/PasterTests.swift`.

**Feature B — Preview**
- Create `Sources/ClipnestCore/Model/ClipItemPreview.swift` — pure preview-eligibility predicate.
- Create `ClipnestApp/Sources/UI/Picker/ItemPreview.swift` — the preview content view.
- Create `ClipnestApp/Sources/UI/Picker/ItemPreviewController.swift` — presentation (popover/child panel) + focus-safe show/hide.
- Modify `ClipnestApp/Sources/UI/Picker/ItemRow.swift` — hover reporting.
- Modify `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift` — `previewTargetID` with delays.
- Modify `ClipnestApp/Sources/UI/Picker/PickerView.swift` — wire hover + present preview.
- Tests: `Tests/ClipnestCoreTests/ClipItemPreviewTests.swift`.

**Feature C — Snippet keyword expansion**
- Modify `Sources/ClipnestCore/Store/SnippetStore.swift` — `findByKeyword` protocol method.
- Modify `Sources/ClipnestCore/Store/InMemorySnippetStore.swift` — impl.
- Modify `Sources/ClipnestCore/Store/SwiftDataSnippetStore.swift` — impl.
- Create `ClipnestApp/Sources/System/SelectedTextAccessing.swift` — protocol + real AX impl.
- Create `ClipnestApp/Sources/System/SnippetExpander.swift` — orchestration.
- Modify `ClipnestApp/Sources/System/HotkeyManager.swift` — `.expandSnippet` name + registration.
- Modify `ClipnestApp/Sources/App/AppEnvironment.swift` — construct + wire expander/hotkey.
- Tests: `Tests/ClipnestCoreTests/SnippetStoreTests.swift`, `Tests/ClipnestCoreTests/SwiftDataSnippetStoreTests.swift`, and `ClipnestApp/Tests/…/SnippetExpanderTests.swift` (see Task 8 note on app-target testability).

---

## Task 1: Store RTF bytes when capturing rich text

**Files:**
- Modify: `Sources/ClipnestCore/Clipboard/PasteboardReader.swift` (`readRichText`)
- Test: `Tests/ClipnestCoreTests/PasteboardReaderTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `PasteboardReader.read(from:)` now returns a `.richText` `Classification` whose `rawData == <the .rtf bytes>`. `ClipboardMonitor.checkNow()` (unchanged) will therefore write those bytes to `BlobStore` and set `ClipItem.blobPath`.

- [ ] **Step 1: Write the failing test**

Add to `PasteboardReaderTests.swift` (a `FakePasteboard`-style reader is already used elsewhere in this file — reuse the existing test helper that conforms to `PasteboardReading`; if the existing helper is named differently, adapt the call, but do not create a second fake):

```swift
@Test("Rich text classification carries the RTF bytes as rawData for BlobStore")
func richTextStoresRawRTFData() throws {
  let rtfData = Data("{\\rtf1\\ansi bold}".utf8)
  let pasteboard = FakePasteboard(types: [.rtf, .string])
  pasteboard.dataByType[.rtf] = rtfData
  pasteboard.stringByType[.string] = "bold"

  let reader = PasteboardReader()
  let classification = try #require(reader.read(from: pasteboard))

  #expect(classification.kind == .richText)
  #expect(classification.rawData == rtfData)
  #expect(classification.previewText == "bold")
}
```

If the existing fake in this file has different member names (`dataByType`/`stringByType`/`types`), match them exactly instead — read the top of `PasteboardReaderTests.swift` first and reuse its fake verbatim.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter richTextStoresRawRTFData`
Expected: FAIL — `classification.rawData` is `nil` (reader currently discards RTF bytes).

- [ ] **Step 3: Write minimal implementation**

In `PasteboardReader.readRichText`, add `rawData: rtfData` to the returned `Classification`:

```swift
private func readRichText(
  _ rtfData: Data,
  from pasteboard: PasteboardReading
) -> Classification {
  let previewText = plainTextPreview(forRTF: rtfData, fallbackFrom: pasteboard)
  return Classification(
    kind: .richText,
    previewText: previewText,
    contentHash: BlobStore.contentHash(of: rtfData),
    byteSize: rtfData.count,
    rawData: rtfData
  )
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PasteboardReader`
Expected: PASS (the new test and all existing `PasteboardReaderTests`).

- [ ] **Step 5: Stage**

```bash
git add Sources/ClipnestCore/Clipboard/PasteboardReader.swift Tests/ClipnestCoreTests/PasteboardReaderTests.swift
```
(Do not commit — the user commits.)

---

## Task 2: `PasteContent.richText` + `writeRichText` + Paster support

**Files:**
- Modify: `Sources/ClipnestCore/Paste/Paster.swift` (`PasteContent`, `PasteboardWriting`, `NSPasteboard` extension, `Paster.paste`)
- Test: `Tests/ClipnestCoreTests/PasterTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `enum PasteContent { case text(String); case image(Data); case file(URL); case richText(rtf: Data, plain: String) }`
  - `protocol PasteboardWriting { … ; func writeRichText(rtf: Data, plain: String) }`
  - `Paster.paste(_:targetingFrontmostApp:)` handles `.richText` by calling `writeRichText(rtf:plain:)`.

- [ ] **Step 1: Write the failing test**

In `PasterTests.swift`, first extend the existing `FakePasteboardWriting` (add rich-text recording without removing any existing member):

```swift
// add inside FakePasteboardWriting
private(set) var writtenRTF: Data?
private(set) var writtenPlain: String?

func writeRichText(rtf: Data, plain: String) {
  writtenRTF = rtf
  writtenPlain = plain
  writeCount += 1
  changeCount += 1
}
```

Then add the test:

```swift
@Test("Rich text content writes BOTH the RTF and the plain-text representation in one write")
func richTextWritesBothRepresentations() async throws {
  let pasteboard = FakePasteboardWriting()
  let synthesizer = MockEventSynthesizing()
  let paster = Paster(
    pasteboard: pasteboard,
    eventSynthesizer: synthesizer,
    isAccessibilityGranted: { true },
    synthesisDelay: .zero
  )
  let rtf = Data("{\\rtf1\\ansi bold}".utf8)

  try await paster.paste(.richText(rtf: rtf, plain: "bold"), targetingFrontmostApp: target)

  #expect(pasteboard.writtenRTF == rtf)
  #expect(pasteboard.writtenPlain == "bold")
  #expect(pasteboard.writeCount == 1)
  #expect(synthesizer.invocationCount == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter richTextWritesBothRepresentations`
Expected: FAIL — `PasteContent.richText` does not exist / `writeRichText` not on protocol (compile error is an acceptable "fail").

- [ ] **Step 3: Write minimal implementation**

In `Paster.swift`:

Add the case to `PasteContent`:
```swift
public enum PasteContent: Equatable, Sendable {
  case text(String)
  case image(Data)
  case file(URL)
  case richText(rtf: Data, plain: String)
}
```

Add to the `PasteboardWriting` protocol:
```swift
/// Clears the pasteboard once, then writes BOTH the `.rtf` and `.string`
/// representations so a paste target picks the richest form it supports.
func writeRichText(rtf: Data, plain: String)
```

Implement in the `NSPasteboard` extension:
```swift
public func writeRichText(rtf: Data, plain: String) {
  clearContents()
  setData(rtf, forType: .rtf)
  setString(plain, forType: .string)
}
```

Handle the case in `Paster.paste`, inside the `switch content`:
```swift
case .richText(let rtf, let plain):
  pasteboard.writeRichText(rtf: rtf, plain: plain)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter Paster`
Expected: PASS (new test + all existing `PasterTests`).

- [ ] **Step 5: Stage**

```bash
git add Sources/ClipnestCore/Paste/Paster.swift Tests/ClipnestCoreTests/PasterTests.swift
```

---

## Task 3: Route `plainText` through `PickerViewModel`

**Files:**
- Modify: `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift` (`pasteContent(for:)`, `select(_:)`, `selectHighlighted()`)

**Interfaces:**
- Consumes: `PasteContent.richText(rtf:plain:)` (Task 2), `ClipItem.blobPath`, `BlobStore.read(blobPath:)`.
- Produces:
  - `func pasteContent(for item: ClipItem, plainText: Bool) -> PasteContent?`
  - `func select(_ item: ClipItem, plainText: Bool = false)`
  - `func selectHighlighted(plainText: Bool = false)`

**Testing note:** this is app-target code with no unit-test target today (see Task 8). Verification here is the app **build** plus the runtime check folded into Task 4. Keep the logic changes minimal and mechanical.

- [ ] **Step 1: Update `pasteContent(for:)` to take a `plainText` flag**

Replace the existing `pasteContent(for:)` with:

```swift
private func pasteContent(for item: ClipItem, plainText: Bool) -> PasteContent? {
  if plainText {
    // Strip: paste the plain form for any text-bearing kind.
    switch item.kind {
    case .text, .link, .richText:
      return .text(item.previewText)
    case .image, .file:
      break  // no plain form — fall through to normal handling below
    }
  }

  switch item.kind {
  case .text, .link:
    return .text(item.previewText)
  case .richText:
    // Rich by default: read the stored RTF blob. Legacy richText items
    // captured before RTF was stored have no blob → paste the plain
    // previewText rather than no-op.
    guard let blobPath = item.blobPath else { return .text(item.previewText) }
    do {
      let rtf = try blobStore.read(blobPath: blobPath)
      return .richText(rtf: rtf, plain: item.previewText)
    } catch {
      Self.logger.error(
        "Failed to load RTF blob for paste (item \(item.id, privacy: .public)): \(String(describing: error))"
      )
      return .text(item.previewText)
    }
  case .image:
    guard let blobPath = item.blobPath else { return nil }
    do {
      return .image(try blobStore.read(blobPath: blobPath))
    } catch {
      Self.logger.error(
        "Failed to load image blob for paste (item \(item.id, privacy: .public)): \(String(describing: error))"
      )
      return nil
    }
  case .file:
    guard let fileReference = item.fileReference, let url = URL(string: fileReference) else {
      return nil
    }
    return .file(url)
  }
}
```

- [ ] **Step 2: Thread the flag through `select` and `selectHighlighted`**

```swift
func select(_ item: ClipItem, plainText: Bool = false) {
  guard let content = pasteContent(for: item, plainText: plainText) else { return }
  pasteAndDismiss(content)
}
```

```swift
func selectHighlighted(plainText: Bool = false) {
  Task { [weak self] in
    guard let self else { return }
    await self.flushActiveTabPendingQuery()
    switch self.activeTab {
    case .history, .pinned:
      guard let item = self.highlightedItem else { return }
      self.select(item, plainText: plainText)
    case .snippets:
      guard let snippet = self.highlightedSnippet else { return }
      self.pasteSnippet(snippet)  // snippets are already plain; flag irrelevant
    }
  }
}
```

Leave the `ItemRow` `onSelect: { viewModel.select(item) }` call sites unchanged — they use the `plainText: false` default (normal click = rich).

- [ ] **Step 3: Build the app to verify it compiles**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -project ClipnestApp.xcodeproj -scheme ClipnestApp CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Lint**

Run: `swift format lint --recursive --strict ClipnestApp/Sources`
Expected: clean.

- [ ] **Step 5: Stage**

```bash
git add ClipnestApp/Sources/UI/Picker/PickerViewModel.swift
```

---

## Task 4: ⌥Return key binding + footer hint

**Files:**
- Modify: `ClipnestApp/Sources/UI/Picker/PickerView.swift` (`handle(_:)`, `shortcutHints`)

**Interfaces:**
- Consumes: `selectHighlighted(plainText:)` (Task 3).
- Produces: ⌥Return → plain paste; plain Return → rich/default paste (unchanged).

- [ ] **Step 1: Add the ⌥Return case before the plain `.return` case**

In `handle(_:)`, insert this case **above** the existing `case .return:`:

```swift
case .return where press.modifiers.contains(.option):
  viewModel.selectHighlighted(plainText: true)
  return .handled
```

Leave the existing `case .return:` (which now only matches Return without Option) calling `viewModel.selectHighlighted()` (rich default). The field's `.onSubmit { viewModel.selectHighlighted() }` also stays (rich default) — `.onSubmit` fires only for plain Return.

- [ ] **Step 2: Add the footer hint**

In `shortcutHints`, change the base parts line to include the plain-paste hint:

```swift
var parts = ["↑↓ move", "⏎ paste", "⌥⏎ plain", "⌘F search"]
```

- [ ] **Step 3: Build the app**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -project ClipnestApp.xcodeproj -scheme ClipnestApp CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual-verify (flag, do not claim as automated)**

Launch the built app. Copy bold/styled text from TextEdit or Pages. Open the picker, highlight that item:
- Press **Return** into a rich-text field (e.g. TextEdit) → pastes **with** formatting.
- Press **⌥Return** → pastes **plain**.
- For a plain-text item, both behave identically.
Record the result in the task report as a manual check (headless cannot prove keypress routing).

- [ ] **Step 5: Lint + stage**

Run: `swift format lint --recursive --strict ClipnestApp/Sources` (expect clean)

```bash
git add ClipnestApp/Sources/UI/Picker/PickerView.swift
```

---

## Task 5: `SnippetStore.findByKeyword` — protocol + in-memory impl

**Files:**
- Modify: `Sources/ClipnestCore/Store/SnippetStore.swift` (protocol)
- Modify: `Sources/ClipnestCore/Store/InMemorySnippetStore.swift` (impl)
- Test: `Tests/ClipnestCoreTests/SnippetStoreTests.swift`

**Interfaces:**
- Consumes: `Snippet` (`keyword`, `createdAt`).
- Produces: `func findByKeyword(_ keyword: String) async throws -> Snippet?` on `SnippetStore` — returns the newest snippet whose `keyword`, trimmed + case-folded, equals the trimmed + case-folded argument; `nil` if the argument is blank or no snippet matches.

- [ ] **Step 1: Write the failing tests**

Add to `SnippetStoreTests.swift` (match the file's existing `@Suite`/helper style; if it already has a helper to build a store, reuse it):

```swift
@Test("findByKeyword matches exactly, case-insensitively, and trimmed")
func findByKeywordExactCaseInsensitiveTrimmed() async throws {
  let store = InMemorySnippetStore()
  _ = try await store.create(Snippet(title: "Sig", body: "Best, Aayush", keyword: "sig"))

  #expect(try await store.findByKeyword("sig")?.body == "Best, Aayush")
  #expect(try await store.findByKeyword("SIG")?.body == "Best, Aayush")
  #expect(try await store.findByKeyword("  sig  ")?.body == "Best, Aayush")
}

@Test("findByKeyword returns nil for no match, blank input, and keyword-less snippets")
func findByKeywordNoMatch() async throws {
  let store = InMemorySnippetStore()
  _ = try await store.create(Snippet(title: "Plain", body: "no keyword", keyword: nil))
  _ = try await store.create(Snippet(title: "Empty kw", body: "blank", keyword: "   "))

  #expect(try await store.findByKeyword("sig") == nil)
  #expect(try await store.findByKeyword("") == nil)
  #expect(try await store.findByKeyword("   ") == nil)
}

@Test("findByKeyword returns the newest snippet when multiple share a keyword")
func findByKeywordNewestWins() async throws {
  let store = InMemorySnippetStore()
  let older = Snippet(
    title: "Old", body: "old body", keyword: "addr",
    createdAt: Date(timeIntervalSince1970: 1000))
  let newer = Snippet(
    title: "New", body: "new body", keyword: "addr",
    createdAt: Date(timeIntervalSince1970: 2000))
  _ = try await store.create(older)
  _ = try await store.create(newer)

  #expect(try await store.findByKeyword("addr")?.body == "new body")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter findByKeyword`
Expected: FAIL — `findByKeyword` not defined (compile error acceptable).

- [ ] **Step 3: Add to the protocol**

In `SnippetStore.swift`, add to the `SnippetStore` protocol:

```swift
/// Returns the newest snippet whose `keyword`, whitespace-trimmed and
/// case-folded, equals `keyword` similarly normalized. `nil` if `keyword`
/// is blank once trimmed, or no snippet matches. Snippets with a `nil` or
/// blank keyword never match. Powers the global snippet-expansion hotkey.
func findByKeyword(_ keyword: String) async throws -> Snippet?
```

- [ ] **Step 4: Implement in `InMemorySnippetStore`**

```swift
public func findByKeyword(_ keyword: String) async throws -> Snippet? {
  let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  guard !needle.isEmpty else { return nil }
  return
    snippetsByID.values
    .filter { snippet in
      guard
        let candidate = snippet.keyword?
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        !candidate.isEmpty
      else { return false }
      return candidate == needle
    }
    .sorted { $0.createdAt > $1.createdAt }
    .first
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter Snippet`
Expected: PASS (new tests + all existing `SnippetStoreTests`).

- [ ] **Step 6: Lint + stage**

Run: `swift format lint --recursive --strict Sources Tests` (expect clean)

```bash
git add Sources/ClipnestCore/Store/SnippetStore.swift Sources/ClipnestCore/Store/InMemorySnippetStore.swift Tests/ClipnestCoreTests/SnippetStoreTests.swift
```

---

## Task 6: `findByKeyword` — SwiftData impl (no migration)

**Files:**
- Modify: `Sources/ClipnestCore/Store/SwiftDataSnippetStore.swift`
- Test: `Tests/ClipnestCoreTests/SwiftDataSnippetStoreTests.swift`

**Interfaces:**
- Consumes: `SnippetStore.findByKeyword` (Task 5), `SwiftDataSnippetStore.makeTestContainer()`.
- Produces: same behavior as Task 5's in-memory impl, backed by SwiftData. **No new `@Model` attribute** — fetches records with a non-nil `keyword` (sorted newest-first) and filters in Swift, so the existing `SnippetRecord` schema is untouched.

- [ ] **Step 1: Write the failing tests**

Add to `SwiftDataSnippetStoreTests.swift` (reuse the file's existing `makeTestContainer()` setup pattern):

```swift
@Test("SwiftData findByKeyword matches trimmed + case-insensitively, newest wins, blank/none ignored")
func swiftDataFindByKeyword() async throws {
  let store = SwiftDataSnippetStore(modelContainer: try SwiftDataSnippetStore.makeTestContainer())
  _ = try await store.create(
    Snippet(
      title: "Old", body: "old body", keyword: "addr",
      createdAt: Date(timeIntervalSince1970: 1000)))
  _ = try await store.create(
    Snippet(
      title: "New", body: "new body", keyword: "ADDR",
      createdAt: Date(timeIntervalSince1970: 2000)))
  _ = try await store.create(Snippet(title: "None", body: "x", keyword: nil))

  #expect(try await store.findByKeyword("  addr ")?.body == "new body")
  #expect(try await store.findByKeyword("nope") == nil)
  #expect(try await store.findByKeyword("  ") == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter swiftDataFindByKeyword`
Expected: FAIL — `findByKeyword` not implemented on `SwiftDataSnippetStore` (compile error acceptable).

- [ ] **Step 3: Implement**

Add to `SwiftDataSnippetStore` (in the `// MARK: - SnippetStore` section):

```swift
public func findByKeyword(_ keyword: String) async throws -> Snippet? {
  let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  guard !needle.isEmpty else { return nil }
  // Fetch only keyworded records, newest-first, then match in Swift — the
  // trim + case-fold on an optional field isn't expressible in a
  // `#Predicate`, and adding a stored `normalizedKeyword` would be a schema
  // change (migration). Snippet counts are small (user-authored), so
  // fetching all keyworded rows is cheap.
  let predicate = #Predicate<SnippetRecord> { $0.keyword != nil }
  var descriptor = FetchDescriptor<SnippetRecord>(predicate: predicate)
  descriptor.sortBy = [SortDescriptor(\SnippetRecord.createdAt, order: .reverse)]
  let records = try fetch(descriptor: descriptor)
  let match = records.first { record in
    guard
      let candidate = record.keyword?
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    else { return false }
    return candidate == needle
  }
  return match?.asSnippet()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SwiftDataSnippet`
Expected: PASS (new test + all existing `SwiftDataSnippetStoreTests`).

- [ ] **Step 5: Full core suite (guards against regressions/migration errors)**

Run: `swift test`
Expected: all green.

- [ ] **Step 6: Lint + stage**

Run: `swift format lint --recursive --strict Sources Tests` (expect clean)

```bash
git add Sources/ClipnestCore/Store/SwiftDataSnippetStore.swift Tests/ClipnestCoreTests/SwiftDataSnippetStoreTests.swift
```

---

## Task 7: `SelectedTextAccessing` protocol + real AX implementation

**Files:**
- Create: `ClipnestApp/Sources/System/SelectedTextAccessing.swift`

**Interfaces:**
- Consumes: `ApplicationServices` (AX).
- Produces:
  - `protocol SelectedTextAccessing { func readSelectedText() -> String?; @discardableResult func replaceSelectedText(with text: String) -> Bool }`
  - `struct AXSelectedTextAccessor: SelectedTextAccessing` — the real implementation.

**Testing note:** the concrete AX implementation is manual-verify only (it drives another app's UI). The protocol exists so Task 8's orchestration is unit-testable with a mock. No test in this task.

- [ ] **Step 1: Create the file**

```swift
// SelectedTextAccessing.swift
//
// Reads and replaces the currently-selected text in the frontmost app via
// the Accessibility API (AX) — WITHOUT touching the pasteboard. Used by the
// snippet-expansion hotkey (see `SnippetExpander`). Abstracted behind a
// protocol so the expander's decision logic is unit-testable with a mock;
// the real AX implementation is manual-verify only.
//
// `@preconcurrency import ApplicationServices`: the AX C API predates Swift
// concurrency auditing (same reason `PermissionsManager` needs it — see
// project-context.md D13), so importing it plainly can trip strict-
// concurrency diagnostics on its global constants.

import AppKit
@preconcurrency import ApplicationServices

/// Reads / replaces the frontmost app's current text selection via AX.
/// Every method returns gracefully (nil / false) when AX is unavailable or
/// the focused element doesn't expose a text selection — never crashes,
/// never touches the pasteboard.
protocol SelectedTextAccessing {
  /// The currently-selected text in the focused UI element, or `nil` if
  /// there's no selection, no focused element, or AX can't read it.
  func readSelectedText() -> String?

  /// Replaces the current selection with `text` in place. Returns `true` on
  /// success, `false` if AX refused (element not settable / not supported).
  @discardableResult
  func replaceSelectedText(with text: String) -> Bool
}

/// Production `SelectedTextAccessing` backed by the system-wide AX element.
struct AXSelectedTextAccessor: SelectedTextAccessing {
  func readSelectedText() -> String? {
    guard let focused = focusedElement() else { return nil }
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(
      focused, kAXSelectedTextAttribute as CFString, &value)
    guard result == .success, let string = value as? String else { return nil }
    return string
  }

  @discardableResult
  func replaceSelectedText(with text: String) -> Bool {
    guard let focused = focusedElement() else { return false }
    let result = AXUIElementSetAttributeValue(
      focused, kAXSelectedTextAttribute as CFString, text as CFString)
    return result == .success
  }

  /// The system-wide focused UI element, or `nil` if none / AX unavailable.
  private func focusedElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var focused: AnyObject?
    let result = AXUIElementCopyAttributeValue(
      systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
    guard result == .success else { return nil }
    // `focused` is an AXUIElement (a CFType); bridge it back.
    guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    return (focused as! AXUIElement)
  }
}
```

- [ ] **Step 2: Add the new file to the Xcode project & build**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -project ClipnestApp.xcodeproj -scheme ClipnestApp CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`. (XcodeGen picks up new files under `Sources/` automatically.)

- [ ] **Step 3: Lint + stage**

Run: `swift format lint --recursive --strict ClipnestApp/Sources` (expect clean)

```bash
git add ClipnestApp/Sources/System/SelectedTextAccessing.swift
```

---

## Task 8: `SnippetExpander` orchestration

**Files:**
- Create: `ClipnestApp/Sources/System/SnippetExpander.swift`
- Test: `ClipnestApp/Tests/ClipnestAppTests/SnippetExpanderTests.swift`

**Interfaces:**
- Consumes: `SelectedTextAccessing` (Task 7), `SnippetStore.findByKeyword` (Task 5/6).
- Produces: `final class SnippetExpander` with `func expand() async` — reads the selection, looks it up, replaces on match, beeps on no-match. A `beep` closure is injected so tests observe the no-match path without a real sound.

**App-test-target note:** the base project has no `ClipnestApp` unit-test target. If one already exists in `project.yml`, add the test there. If not, add a minimal test target to `ClipnestApp/project.yml` (a `ClipnestAppTests` bundle depending on the app) as part of this task — this is the first piece of app-layer logic worth unit-testing. If adding a test target proves disproportionate, fall back to exercising the same decision logic by keeping it in a pure, injectable form and testing it via a tiny `ClipnestCore`-side helper is NOT possible here (it depends on app-only `SelectedTextAccessing`); in that case document the decision and rely on the mock-driven test in the app target. Prefer adding the app test target.

- [ ] **Step 1: Write the failing test**

`ClipnestApp/Tests/ClipnestAppTests/SnippetExpanderTests.swift`:

```swift
import ClipnestCore
import Testing

@testable import Clipnest

private final class MockSelectedText: SelectedTextAccessing, @unchecked Sendable {
  var selection: String?
  private(set) var replacedWith: String?
  var replaceSucceeds = true

  func readSelectedText() -> String? { selection }

  @discardableResult
  func replaceSelectedText(with text: String) -> Bool {
    replacedWith = text
    return replaceSucceeds
  }
}

@Suite("SnippetExpander")
struct SnippetExpanderTests {
  @Test("On a keyword match, replaces the selection with the snippet body and never beeps")
  func matchReplaces() async throws {
    let store = InMemorySnippetStore()
    _ = try await store.create(Snippet(title: "Sig", body: "Best, Aayush", keyword: "sig"))
    let ax = MockSelectedText()
    ax.selection = "sig"
    var beeped = false
    let expander = SnippetExpander(
      snippetStore: store, selectedText: ax, beep: { beeped = true })

    await expander.expand()

    #expect(ax.replacedWith == "Best, Aayush")
    #expect(beeped == false)
  }

  @Test("On no keyword match, beeps and never replaces")
  func noMatchBeeps() async throws {
    let store = InMemorySnippetStore()
    let ax = MockSelectedText()
    ax.selection = "unknown"
    var beeped = false
    let expander = SnippetExpander(
      snippetStore: store, selectedText: ax, beep: { beeped = true })

    await expander.expand()

    #expect(ax.replacedWith == nil)
    #expect(beeped == true)
  }

  @Test("On an empty/nil selection, beeps and never replaces")
  func emptySelectionBeeps() async throws {
    let store = InMemorySnippetStore()
    _ = try await store.create(Snippet(title: "Sig", body: "b", keyword: "sig"))
    let ax = MockSelectedText()
    ax.selection = nil
    var beeped = false
    let expander = SnippetExpander(
      snippetStore: store, selectedText: ax, beep: { beeped = true })

    await expander.expand()

    #expect(ax.replacedWith == nil)
    #expect(beeped == true)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ClipnestApp && xcodebuild -project ClipnestApp.xcodeproj -scheme ClipnestAppTests CODE_SIGNING_ALLOWED=NO test` (or the scheme name the test target generates)
Expected: FAIL — `SnippetExpander` not defined. (If the test target needs creating first, do that in this step so the failure is "not defined," not "no such scheme.")

- [ ] **Step 3: Implement `SnippetExpander`**

```swift
// SnippetExpander.swift
//
// Backs the global snippet-expansion hotkey (⌥⌘E): reads the current
// selection via AX, looks it up as a snippet keyword, and replaces the
// selection with the snippet body on a match — all WITHOUT touching the
// pasteboard. No match / no selection / AX-unsupported → a system beep.

import AppKit
import ClipnestCore
import os

final class SnippetExpander {
  private static let logger = Logger(subsystem: "com.clipnest.app", category: "SnippetExpander")

  private let snippetStore: any SnippetStore
  private let selectedText: any SelectedTextAccessing
  private let beep: () -> Void

  init(
    snippetStore: any SnippetStore,
    selectedText: any SelectedTextAccessing = AXSelectedTextAccessor(),
    beep: @escaping () -> Void = { NSSound.beep() }
  ) {
    self.snippetStore = snippetStore
    self.selectedText = selectedText
    self.beep = beep
  }

  /// Reads the current selection, and if it matches a snippet keyword,
  /// replaces the selection with that snippet's body. Otherwise beeps.
  func expand() async {
    guard
      let selection = selectedText.readSelectedText(),
      !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      beep()
      return
    }

    let match: Snippet?
    do {
      match = try await snippetStore.findByKeyword(selection)
    } catch {
      Self.logger.error("findByKeyword failed: \(String(describing: error))")
      beep()
      return
    }

    guard let snippet = match else {
      beep()
      return
    }

    if !selectedText.replaceSelectedText(with: snippet.body) {
      // AX refused (e.g. Chrome/Electron) — safe no-op with feedback.
      beep()
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ClipnestApp && xcodebuild -project ClipnestApp.xcodeproj -scheme ClipnestAppTests CODE_SIGNING_ALLOWED=NO test`
Expected: PASS (all three tests).

- [ ] **Step 5: Lint + stage**

Run: `swift format lint --recursive --strict ClipnestApp` (expect clean)

```bash
git add ClipnestApp/Sources/System/SnippetExpander.swift ClipnestApp/Tests ClipnestApp/project.yml
```
(Include `project.yml` only if a test target was added.)

---

## Task 9: Register the ⌥⌘E hotkey and wire the expander

**Files:**
- Modify: `ClipnestApp/Sources/System/HotkeyManager.swift`
- Modify: `ClipnestApp/Sources/App/AppEnvironment.swift`

**Interfaces:**
- Consumes: `SnippetExpander` (Task 8), `KeyboardShortcuts`.
- Produces: `KeyboardShortcuts.Name.expandSnippet` (default ⌥⌘E); `AppEnvironment` owns a `SnippetExpander` and registers the hotkey to it.

- [ ] **Step 1: Add the shortcut name**

In `HotkeyManager.swift`, add alongside `.togglePicker`:

```swift
/// Expands the selected text as a snippet keyword (see `SnippetExpander`).
/// Default **⌥⌘E**. Exposed as a `Name` so a future Settings recorder can
/// bind to it directly.
static let expandSnippet = Self(
  "expandSnippet",
  initial: .init(.e, modifiers: [.command, .option])
)
```

Add a registration entry point to `HotkeyManager`:

```swift
/// Registers `.expandSnippet` to call `onExpand`. Call once, from
/// `AppEnvironment`.
static func registerExpandSnippet(onExpand: @escaping () -> Void) {
  KeyboardShortcuts.onKeyDown(for: .expandSnippet, action: onExpand)
}
```

- [ ] **Step 2: Construct + wire the expander in `AppEnvironment`**

Add a stored property near the other `let`s:

```swift
let snippetExpander: SnippetExpander
```

Construct it in `init()` after `snippetStore` is set:

```swift
self.snippetExpander = SnippetExpander(snippetStore: snippetStore)
```

Extend `registerHotkey()` (or add a sibling call from `AppDelegate`) so both hotkeys register together:

```swift
func registerHotkey() {
  HotkeyManager.register { [weak self] in self?.showPicker() }
  HotkeyManager.registerExpandSnippet { [weak self] in
    guard let self else { return }
    Task { await self.snippetExpander.expand() }
  }
}
```

- [ ] **Step 3: Build the app**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -project ClipnestApp.xcodeproj -scheme ClipnestApp CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual-verify (flag, not automated)**

With Accessibility granted to the built app: create a snippet with keyword `sig`. In TextEdit, type `sig`, select it, press **⌥⌘E** → it becomes the snippet body, clipboard unchanged. Type `nope`, select, press ⌥⌘E → system beep, nothing replaced. Try in Chrome → beep (AX unsupported), no crash, clipboard still intact. Record as a manual check.

- [ ] **Step 5: Lint + stage**

Run: `swift format lint --recursive --strict ClipnestApp/Sources` (expect clean)

```bash
git add ClipnestApp/Sources/System/HotkeyManager.swift ClipnestApp/Sources/App/AppEnvironment.swift
```

---

## Task 10: Preview-eligibility predicate (pure, Core)

**Files:**
- Create: `Sources/ClipnestCore/Model/ClipItemPreview.swift`
- Test: `Tests/ClipnestCoreTests/ClipItemPreviewTests.swift`

**Interfaces:**
- Consumes: `ClipItem`, `ItemKind`.
- Produces: `extension ClipItem { var isPreviewWorthy: Bool }` — `true` for `.image`/`.file` always; for `.text`/`.richText`/`.link` only when `previewText` is long (> `ClipItem.previewTextLengthThreshold`) or contains a newline; `false` for short single-line text.

- [ ] **Step 1: Write the failing tests**

`ClipItemPreviewTests.swift`:

```swift
import Foundation
import Testing

@testable import ClipnestCore

@Suite("ClipItem preview eligibility")
struct ClipItemPreviewTests {
  private func item(_ kind: ItemKind, _ preview: String) -> ClipItem {
    ClipItem(kind: kind, previewText: preview, contentHash: "h")
  }

  @Test("Images and files are always preview-worthy")
  func imagesAndFilesAlwaysWorthy() {
    #expect(item(.image, "Image, 4×4").isPreviewWorthy)
    #expect(item(.file, "report.pdf").isPreviewWorthy)
  }

  @Test("Short single-line text is not preview-worthy")
  func shortTextNotWorthy() {
    #expect(item(.text, "hello").isPreviewWorthy == false)
    #expect(item(.link, "https://a.co").isPreviewWorthy == false)
  }

  @Test("Long or multi-line text is preview-worthy")
  func longOrMultilineTextWorthy() {
    #expect(item(.text, String(repeating: "x", count: 200)).isPreviewWorthy)
    #expect(item(.text, "line one\nline two").isPreviewWorthy)
    #expect(item(.richText, String(repeating: "y", count: 200)).isPreviewWorthy)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "preview eligibility"`
Expected: FAIL — `isPreviewWorthy` not defined.

- [ ] **Step 3: Implement**

```swift
// ClipItemPreview.swift
//
// Pure predicate deciding whether a ClipItem is worth showing in the
// picker's preview surface (see ItemPreview / ItemPreviewController in
// ClipnestApp). Kept in Core so it's unit-testable without launching the UI.

import Foundation

extension ClipItem {
  /// Text longer than this (or containing a newline) is considered too big
  /// to fully read in a single-line row, so it earns a preview. Tuned to a
  /// value comfortably longer than a typical row's visible width.
  public static let previewTextLengthThreshold = 80

  /// Whether this item should get a preview surface. `.image`/`.file`
  /// always (the row only shows a tiny thumbnail/icon). Text-bearing kinds
  /// only when the content is long or multi-line — short, fully-visible
  /// single-line text gains nothing from a preview.
  public var isPreviewWorthy: Bool {
    switch kind {
    case .image, .file:
      return true
    case .text, .richText, .link:
      return previewText.count > Self.previewTextLengthThreshold
        || previewText.contains(where: \.isNewline)
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "preview eligibility"`
Expected: PASS.

- [ ] **Step 5: Lint + stage**

Run: `swift format lint --recursive --strict Sources Tests` (expect clean)

```bash
git add Sources/ClipnestCore/Model/ClipItemPreview.swift Tests/ClipnestCoreTests/ClipItemPreviewTests.swift
```

---

## Task 11: `ItemPreview` content view

**Files:**
- Create: `ClipnestApp/Sources/UI/Picker/ItemPreview.swift`

**Interfaces:**
- Consumes: `ClipItem`, `BlobStore`, `ItemThumbnailCache` (existing), `ClipItem.isPreviewWorthy` (Task 10).
- Produces: `struct ItemPreview: View` taking `item: ClipItem` and `blobStore: BlobStore`, rendering the per-kind preview content.

**Testing note:** SwiftUI rendering is manual-verify. This task's gate is the app build + a lint pass; visual correctness is checked in Task 12's manual run.

- [ ] **Step 1: Create the view**

```swift
// ItemPreview.swift
//
// The preview surface content for one ClipItem — a full image for `.image`,
// scrollable full text for long/rich/link text, and an icon + path + size
// for `.file`. Presented by `ItemPreviewController`. Never shown for items
// where `isPreviewWorthy` is false (the caller gates on that).

import AppKit
import ClipnestCore
import SwiftUI

struct ItemPreview: View {
  let item: ClipItem
  let blobStore: BlobStore

  /// Max edge length for the rendered preview content.
  private static let maxSide: CGFloat = 360

  var body: some View {
    Group {
      switch item.kind {
      case .image:
        imagePreview
      case .file:
        filePreview
      case .text, .richText, .link:
        textPreview
      }
    }
    .padding(12)
    .frame(maxWidth: Self.maxSide)
  }

  private var textPreview: some View {
    ScrollView {
      Text(item.previewText)
        .font(.body)
        .textSelection(.disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: Self.maxSide)
  }

  @ViewBuilder
  private var imagePreview: some View {
    if let blobPath = item.blobPath,
      let cached = ItemThumbnailCache.shared.image(for: blobPath) {
      Image(nsImage: cached)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: Self.maxSide, maxHeight: Self.maxSide)
    } else {
      AsyncBlobImage(item: item, blobStore: blobStore, maxSide: Self.maxSide)
    }
  }

  private var filePreview: some View {
    HStack(spacing: 10) {
      Image(nsImage: fileIcon)
        .resizable()
        .frame(width: 48, height: 48)
      VStack(alignment: .leading, spacing: 4) {
        Text(item.previewText).font(.headline).lineLimit(2)
        Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var fileIcon: NSImage {
    if let ref = item.fileReference, let url = URL(string: ref), url.isFileURL {
      return NSWorkspace.shared.icon(forFile: url.path)
    }
    return NSWorkspace.shared.icon(for: .data)
  }
}

/// Loads full image bytes off the main thread for the preview, falling back
/// to a progress spinner while loading and to nothing on failure.
private struct AsyncBlobImage: View {
  let item: ClipItem
  let blobStore: BlobStore
  let maxSide: CGFloat
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: maxSide, maxHeight: maxSide)
      } else {
        ProgressView().frame(width: 80, height: 80)
      }
    }
    .task(id: item.blobPath) {
      guard let blobPath = item.blobPath else { return }
      let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
        guard let data = try? blobStore.read(blobPath: blobPath) else { return nil }
        return NSImage(data: data)
      }.value
      guard let loaded else { return }
      ItemThumbnailCache.shared.store(loaded, for: blobPath)
      image = loaded
    }
  }
}
```

Note: verify `ItemThumbnailCache.shared.image(for:)`/`.store(_:for:)` signatures against `ItemThumbnailCache.swift` and match them exactly; if they differ, adjust the calls (do not change the cache).

- [ ] **Step 2: Build the app**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -project ClipnestApp.xcodeproj -scheme ClipnestApp CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Lint + stage**

Run: `swift format lint --recursive --strict ClipnestApp/Sources` (expect clean)

```bash
git add ClipnestApp/Sources/UI/Picker/ItemPreview.swift
```

---

## Task 12: Preview presentation — hover/selection tracking + focus-safe popover

**Files:**
- Create: `ClipnestApp/Sources/UI/Picker/ItemPreviewController.swift`
- Modify: `ClipnestApp/Sources/UI/Picker/ItemRow.swift` (hover reporting)
- Modify: `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift` (`previewTargetID` + delays)
- Modify: `ClipnestApp/Sources/UI/Picker/PickerView.swift` (wire hover + present)

**Interfaces:**
- Consumes: `ItemPreview` (Task 11), `ClipItem.isPreviewWorthy` (Task 10), `PickerViewModel.rows`, `selectedItemID`.
- Produces: `@Published var previewTargetID: ClipItem.ID?` on `PickerViewModel`, updated from hover (400ms) or selection (120ms), hover winning; a presentation surface that shows `ItemPreview` for that item **without stealing search-field focus**.

**Design constraint (hard):** the picker is a non-activating `NSPanel` and the whole keyboard flow depends on the search field retaining first responder (see project-context.md D11). The preview surface MUST NOT take key focus. Use a SwiftUI `.popover` on the row, or `NSPopover` with `.behavior = .semitransient` / a non-key child `NSPanel` — whichever passes the manual focus check in Step 5. If a popover variant steals focus, fall back to a non-activating child `NSPanel` positioned beside the row via the existing `WindowPlacement` helpers.

- [ ] **Step 1: Add `previewTargetID` tracking to `PickerViewModel`**

Add published state + setters (delays make hover win over selection without flicker):

```swift
/// The item whose preview should currently show (hover takes priority over
/// keyboard selection). Driven by `hoverItem(_:)` / selection changes with
/// the debounce delays below. Nil = no preview.
@Published private(set) var previewTargetID: ClipItem.ID?

private var hoveredItemID: ClipItem.ID?
private var previewTask: Task<Void, Never>?
private static let hoverPreviewDelay = Duration.milliseconds(400)
private static let selectionPreviewDelay = Duration.milliseconds(120)

/// Called by `ItemRow.onHover`. `nil` = pointer left the row.
func hoverItem(_ id: ClipItem.ID?) {
  hoveredItemID = id
  schedulePreviewUpdate(delay: id == nil ? .zero : Self.hoverPreviewDelay)
}

/// Call when the keyboard selection changes (from `PickerView`'s
/// `.onChange(of: selectedItemID)`).
func selectionChangedForPreview() {
  schedulePreviewUpdate(delay: Self.selectionPreviewDelay)
}

private func schedulePreviewUpdate(delay: Duration) {
  previewTask?.cancel()
  previewTask = Task { [weak self] in
    guard let self else { return }
    if delay != .zero { try? await Task.sleep(for: delay) }
    if Task.isCancelled { return }
    self.previewTargetID = self.resolvedPreviewTargetID()
  }
}

/// Hover wins over selection; only preview-worthy items qualify.
private func resolvedPreviewTargetID() -> ClipItem.ID? {
  let candidateID = hoveredItemID ?? selectedItemID
  guard let candidateID, let item = rows.first(where: { $0.id == candidateID }),
    item.isPreviewWorthy
  else { return nil }
  return candidateID
}
```

Also cancel `previewTask` in `didHide()` (add `previewTask?.cancel(); previewTask = nil; previewTargetID = nil` to the existing `didHide()` body).

- [ ] **Step 2: Report hover from `ItemRow`**

Add an `onHover` closure param to `ItemRow` and call it from a `.onHover` modifier on the row's content:

```swift
// add to ItemRow's stored properties:
let onHover: (Bool) -> Void

// add to the body's root HStack modifiers (after .onTapGesture):
.onHover { onHover($0) }
```

Update the `ItemRow(...)` call site in `PickerView.list` to pass `onHover: { hovering in viewModel.hoverItem(hovering ? item.id : nil) }`.

- [ ] **Step 3: Present the preview from `PickerView` (focus-safe)**

Create `ItemPreviewController.swift` and use it (or a SwiftUI `.popover`) from `PickerView`. Minimal SwiftUI-popover approach to try first — attach to the list container, anchored to the target row; if it steals focus at runtime, switch to the child-panel controller:

```swift
// ItemPreviewController.swift
//
// Presents `ItemPreview` beside the picker without taking key focus — the
// picker's search field must keep first responder (project-context.md D11).
// A non-activating child NSPanel is the fallback if a SwiftUI/NSPopover
// approach is found to steal focus during manual verification.

import AppKit
import ClipnestCore
import SwiftUI

@MainActor
final class ItemPreviewController {
  private var panel: NSPanel?

  /// Shows `item`'s preview beside `anchorRect` (in screen coords), or hides
  /// if `item` is nil. Never becomes key.
  func update(item: ClipItem?, blobStore: BlobStore, besideAnchor anchorRect: NSRect?) {
    guard let item, let anchorRect else {
      hide()
      return
    }
    let panel = panel ?? makePanel()
    self.panel = panel
    panel.contentViewController = NSHostingController(
      rootView: ItemPreview(item: item, blobStore: blobStore))
    panel.setContentSize(panel.contentViewController?.view.fittingSize ?? NSSize(width: 320, height: 240))
    positionPanel(panel, besideAnchor: anchorRect)
    panel.orderFrontRegardless()  // never makeKey — must not steal focus
  }

  func hide() {
    panel?.orderOut(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered, defer: true)
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.hasShadow = true
    panel.backgroundColor = .clear
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return panel
  }

  private func positionPanel(_ panel: NSPanel, besideAnchor anchorRect: NSRect) {
    // Place to the right of the anchor; nudge onto screen if needed.
    var origin = NSPoint(x: anchorRect.maxX + 8, y: anchorRect.minY)
    if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) })
      ?? NSScreen.main {
      let maxX = screen.visibleFrame.maxX - panel.frame.width
      if origin.x > maxX { origin.x = anchorRect.minX - panel.frame.width - 8 }
    }
    panel.setFrameOrigin(origin)
  }
}
```

Wire it from `AppEnvironment` (own one `ItemPreviewController`) and drive `update(...)` from a `PickerView.onChange(of: viewModel.previewTargetID)`. For the anchor rect, use the picker panel's frame as a coarse anchor if per-row rects are impractical (a first-pass acceptable simplification — the preview sits beside the whole picker, like Maccy). Also add `.onChange(of: viewModel.selectedItemID) { _, _ in viewModel.selectionChangedForPreview() }` to `PickerView.body`.

Keep the exact anchoring/ownership details flexible, but the **non-key, orderFrontRegardless** rule is mandatory.

- [ ] **Step 4: Build the app**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -project ClipnestApp.xcodeproj -scheme ClipnestApp CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual-verify (critical — flag, not automated)**

Launch the app. Open the picker and confirm ALL of:
1. Typing in the search field still works with the preview showing (**focus not stolen** — the hard requirement).
2. Arrow-key selecting a long-text or image row shows its preview after ~120ms.
3. Hovering a different (non-selected) row shows that row's preview after ~400ms; moving the pointer away hides it / reverts to the selected row.
4. Short single-line text rows show **no** preview.
5. No preview jumpiness during fast ↑↓ navigation.
Record results in the task report. If focus is stolen by the chosen surface, switch to the child-panel controller variant before staging.

- [ ] **Step 6: Lint + stage**

Run: `swift format lint --recursive --strict ClipnestApp/Sources` (expect clean)

```bash
git add ClipnestApp/Sources/UI/Picker/ItemPreviewController.swift ClipnestApp/Sources/UI/Picker/ItemRow.swift ClipnestApp/Sources/UI/Picker/PickerViewModel.swift ClipnestApp/Sources/UI/Picker/PickerView.swift ClipnestApp/Sources/App/AppEnvironment.swift
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Feature A (rich paste + ⌥Return strip): Tasks 1–4. ✓ (capture RTF, PasteContent/Paster, viewModel routing incl. legacy fallback, keybinding + footer).
- Feature B (preview: images + truncated text + files, popover, hover+selection, no focus theft): Tasks 10–12. ✓
- Feature C (findByKeyword, AX read/replace, expander, ⌥⌘E, beep on no-match, clipboard-free): Tasks 5–9. ✓
- No migration: Tasks 1/6 explicitly avoid schema changes. ✓
- macOS Shortcuts deferred: no task, matches Non-Goals. ✓

**Placeholder scan:** no TBD/TODO; every code step has real code. Two deliberate implementation-choice notes (preview surface mechanism in Task 12; app-test-target creation in Task 8) are bounded decisions with a stated default and fallback, not missing content.

**Type consistency:** `PasteContent.richText(rtf:plain:)`, `writeRichText(rtf:plain:)`, `findByKeyword(_:) async throws -> Snippet?`, `SelectedTextAccessing.readSelectedText()/replaceSelectedText(with:)`, `SnippetExpander(snippetStore:selectedText:beep:)`, `ClipItem.isPreviewWorthy`, `PickerViewModel.hoverItem(_:)/selectionChangedForPreview()/previewTargetID`, `select(_:plainText:)`, `selectHighlighted(plainText:)` — used consistently across tasks.

**Known runtime-only risks (flagged, not tested headlessly):** ⌥Return keypress routing (Task 4), AX read/replace + hotkey (Task 9), preview focus-retention (Task 12). Each has an explicit manual-verify step.
