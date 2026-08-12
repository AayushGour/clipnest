# Clipnest — Rich Paste, Item Preview & Snippet Keyword Expansion — Design Spec

**Date:** 2026-08-11
**Status:** Approved (design), pending implementation plan
**Type:** Feature batch on the existing Clipnest app
**Supersedes/extends:** `2026-08-06-clipnest-design.md` (base app). This spec adds three features; it does not change any prior decision (D1–D14 in `.claude/project-context.md`).

## Background

Competitive review of Maccy (the leading open-source macOS clipboard manager) surfaced feature gaps. The user selected three to build now:

- **A. Paste without formatting** (⌥Return) — Maccy parity.
- **B. Item preview** for images and long/rich text — Maccy parity.
- **C. Snippet keyword expansion** — a Clipnest differentiator (Maccy has no snippets at all).

macOS **Shortcuts** (App Intents automation) was evaluated and **explicitly deferred to v1.1** by the user — see Non-Goals.

## Goals

- Make ⌥Return paste the selected item stripped to plain text; make normal Return preserve basic rich-text formatting when the source had it.
- Show a preview (image or full text) for the keyboard-selected row and for a hover-targeted row.
- Let the user select text in any app, press a global hotkey, and have Clipnest replace that selection with a snippet body when the selected text matches a snippet keyword — **without ever touching the clipboard**.

## Non-Goals (this batch)

- **macOS Shortcuts / App Intents** — deferred to v1.1. Not built here. (Distinct from in-app keyboard shortcuts, which are in scope.)
- RTF/styled-paste fidelity beyond basic rich text (unchanged from the base spec's non-goals).
- A Settings UI for the new toggles. No Settings scene exists yet; new choices ship as hardcoded defaults and can be surfaced later.
- Preview for content that adds nothing (short, fully-visible single-line text).
- Snippet auto-expansion by inline keystroke watching (rejected — would require global key monitoring; the explicit select-then-hotkey flow is the privacy-clean design).

## Cross-cutting constraints

- **No SwiftData migration required.** Feature A reuses the existing `ClipItem.blobPath`; feature C reuses the existing `Snippet.keyword`. No `@Model` field is added or changed, so no `VersionedSchema`/`SchemaMigrationPlan` is needed (D12/D14's flag does not trigger).
- **Testing** (per `.claude/coding-standards.md` + D2): pure logic lives in `ClipnestCore` and is unit-tested with Swift Testing (`swift test`). System integration (AX, NSPopover, event synthesis) is abstracted behind protocols with mocks; real AX/GUI behavior is manual-verify only and must be flagged, never claimed as tested.
- **Privacy:** never log clipboard/snippet content — metadata only, matching existing `os.Logger` usage.
- **Git:** agents run `git add` on finished files only; the user authors commits (memory: git-no-commit-stage-only).

---

## Feature A — Paste without formatting (⌥Return)

### Behavior
- **Return** (unchanged trigger): pastes the highlighted item. For a `.richText` item that has stored RTF, pastes **with** formatting. For `.text`/`.link`, pastes plain (as today). For `.image`/`.file`, pastes the image/file (as today).
- **⌥Return** (new): pastes the highlighted item **stripped to plain text**. For `.text`/`.link` this is identical to Return. For `.richText`, pastes the plain-text form. For `.image`/`.file`, there is no "plain" form → behaves identically to Return.
- **Legacy `.richText` items** captured before this feature have no RTF blob → Return falls back to pasting `previewText` (plain), never a no-op.

### Why this is more than a keybinding
Clipnest currently stores **no** rich formatting: `PasteboardReader.readRichText` discards the RTF bytes (`rawData` stays nil), and `PickerViewModel.pasteContent(for:)` returns nil for `.richText` (not pasteable at all). So ⌥Return would be indistinguishable from Return until rich content actually flows. This feature makes it flow.

### Components & changes
1. **`PasteboardReader.readRichText`** (`ClipnestCore/Clipboard/PasteboardReader.swift`): set `rawData = rtfData` on the returned `Classification`. `previewText` unchanged (plain summary). No other reader change.
   - `ClipboardMonitor` already writes any non-nil `rawData` to `BlobStore` and sets `blobPath` (`ClipboardMonitor.swift:230`) — so `.richText` items automatically gain an RTF blob. **No `ClipboardMonitor` change.**
2. **`PasteContent`** (`ClipnestCore/Paste/Paster.swift`): add `case richText(rtf: Data, plain: String)`.
3. **`PasteboardWriting`** (same file): add `func writeRichText(rtf: Data, plain: String)` — clears the pasteboard once, then sets **both** `.rtf` and `.string` representations so the target app picks the richest it supports. (Existing `writeString`/`writeData` clear+set a single type; a rich paste needs two types in one clear.)
   - `NSPasteboard` conformance implements it; the test mock records both types written.
4. **`Paster.paste`** (same file): handle the new `.richText` case → `pasteboard.writeRichText(rtf:plain:)`, then the existing accessibility/⌘V tail is unchanged. Strip mode does **not** need a Paster change — the caller routes to `.text` instead (below).
5. **`PickerViewModel`** (`ClipnestApp/Sources/UI/Picker/PickerViewModel.swift`):
   - `pasteContent(for:plainText:)` gains a `plainText` parameter.
     - `plainText == true` → `.text(item.previewText)` for `.text`/`.link`/`.richText` (strip). `.image`/`.file` ignore the flag and paste normally.
     - `plainText == false` → for `.richText`: if `blobPath` present, read RTF from `BlobStore` → `.richText(rtf, plain: previewText)`; if RTF read fails or no blob (legacy), fall back to `.text(previewText)`. `.text`/`.link`/`.image`/`.file` unchanged.
   - `select(_ item:, plainText: Bool = false)` and `selectHighlighted(plainText: Bool = false)` thread the flag through the existing flush-before-commit path.
6. **`PickerView`** (`.../PickerView.swift`): in `handle(_:)`, add a `.return` case guarded by `press.modifiers.contains(.option)` **before** the existing plain `.return` case → `viewModel.selectHighlighted(plainText: true)`. Plain `.return` and the field's `.onSubmit` stay rich-default. Add `⌥⏎ plain` to the shortcut-hint footer.

### Edge cases
- `.onSubmit` carries no modifier info → ⌥Return must be caught by `.onKeyPress`; ensure the option-modified case precedes the plain case so it wins.
- RTF blob read failure → log metadata only, fall back to plain, never crash (matches existing image-blob failure handling).

### Tests (`ClipnestCoreTests`)
- `PasteboardReaderTests`: a `.rtf` pasteboard classification now carries `rawData == rtfData`.
- `PasterTests`: `.richText` writes **both** `.rtf` and `.string` to the mock pasteboard; `.text` (strip) writes only `.string`.
- (App-layer routing of the flag is exercised via `PickerViewModel` where unit-testable; the actual ⌥Return keypress is manual-verify.)

---

## Feature B — Item preview (images + truncated text + files)

### Behavior
- A preview surface appears for:
  - the **keyboard-selected** row (short delay, ~120ms), and
  - a **mouse-hovered** row (longer delay, ~400ms, to avoid flicker while the pointer crosses rows).
- **Hover wins** over keyboard selection when both are active (the mouse is the more recent intent).
- **Content by kind:**
  - `.image` → the full image, scaled to fit a max preview size, read from `BlobStore` via `blobPath`.
  - `.text` / `.richText` / `.link` whose `previewText` is truncated or multi-line → the full text, scrollable.
  - `.file` → large file icon (QuickLook thumbnail if cheap to obtain, else `NSWorkspace.icon`), path, and size.
  - Short, fully-visible single-line text → **no preview** (nothing to add).
- The preview is presented as a **popover/tooltip anchored to the row** (user preference).

### Components & changes
- **New `ItemPreview` view** (`ClipnestApp/Sources/UI/Picker/ItemPreview.swift`): renders the per-kind content above. Reuses `BlobStore.read` for images (same source as `ItemRow`'s thumbnail; larger render) and the existing `ItemThumbnailCache` where applicable.
- **Preview presentation controller** (implementation choice made at build time): **NSPopover** anchored to the row, **or** a lightweight transient child `NSPanel` positioned beside the row — whichever reliably (a) points at/sits beside the correct row and (b) **does not steal first-responder/key focus from the picker's search field**. The picker is a non-activating `NSPanel` and the entire keyboard flow depends on the search field keeping focus (see D11's focus-race history) — this is the hard constraint on this feature.
- **`ItemRow`** (`.../ItemRow.swift`): report hover state (`.onHover`) up to the view model / a shared preview-target binding.
- **`PickerViewModel`**: track a `previewTarget: ClipItem.ID?` derived from (hovered row) ?? (selected row), with the two delays applied. Expose it to `PickerView`.
- A "should this item get a preview at all" predicate (kind + text-length/multiline heuristic) — pure, lives where unit-testable (Core helper or a small pure function on the view model).

### Risks / manual-verify
- Focus retention (must not break typing) — **manual-verify, flagged**, not claimed as tested (headless can't prove NSPopover/child-panel focus behavior).
- Popover jumpiness during fast arrow-key navigation — the ~120ms selection delay mitigates; verify at runtime.

### Tests
- Unit-test the "gets a preview?" predicate and the hover-vs-selection target resolution (pure logic).
- Preview rendering + focus behavior: manual-verify.

---

## Feature C — Snippet keyword expansion (Accessibility, clipboard-free)

### Behavior
1. User types a keyword in any app, **selects** it, and presses the global **expand-snippet hotkey (default ⌥⌘E)**.
2. Clipnest reads the currently selected text via the **Accessibility API (AX)** — not by copying.
3. It looks up a snippet whose `keyword` matches the selected text (**exact, case-insensitive, whitespace-trimmed**; if multiple match, newest wins).
4. **Match** → Clipnest replaces the selection in place with the snippet `body`, via AX (`kAXSelectedTextAttribute` set) — **clipboard untouched**.
5. **No match / empty selection / AX unsupported in that app** → `NSSound.beep()` (standard macOS "nope"). No toast in this batch.

### Why AX, not copy
The user explicitly rejected the copy-based approach: synthesizing ⌘C to read the selection would clobber the user's clipboard and could corrupt later content. Reading **and** writing the selection through AX (`kAXFocusedUIElement` → get/set `kAXSelectedTextAttribute`) leaves the clipboard completely untouched, so no capture-suppression and no clipboard save/restore are needed.

### Components & changes
1. **`SnippetStore.findByKeyword(_:)`** — new protocol method (`ClipnestCore/Store/SnippetStore.swift`), implemented in both `InMemorySnippetStore` and `SwiftDataSnippetStore`. Returns the newest `Snippet` whose `keyword`, trimmed and case-folded, equals the trimmed/case-folded argument; `nil` if none. Pure, fully unit-testable. (The existing `query(text:)` deliberately ignores `keyword`, so this is genuinely new.)
2. **`SelectedTextAccessing` protocol** (app-side, `ClipnestApp/Sources/System/`) — `readSelectedText() -> String?` and `replaceSelectedText(with: String) -> Bool`. Real implementation uses `AXUIElementCreateSystemWide()` → `kAXFocusedUIElementAttribute` → get/set `kAXSelectedTextAttribute`. A mock backs unit tests of the expander logic. Lives app-side alongside `PermissionsManager` (system integration, not Core), and uses `@preconcurrency import ApplicationServices` if any unaudited AX constant trips Swift 6 strict concurrency (precedent: D13).
3. **`SnippetExpander`** (app-side): orchestrates read → `findByKeyword` → replace-or-beep. The read→lookup→decision logic is testable with a mock `SelectedTextAccessing` + a real `InMemorySnippetStore`; only the concrete AX calls are manual-verify.
4. **`HotkeyManager`** (`.../HotkeyManager.swift`): add `KeyboardShortcuts.Name.expandSnippet`, `initial: .init(.e, modifiers: [.command, .option])` (⌥⌘E), following the exact pattern of the existing `.togglePicker`. Add a `register(onExpand:)` entry point (or extend the existing registration).
5. **`AppEnvironment`** (`.../AppEnvironment.swift`): construct the real `SelectedTextAccessing` + `SnippetExpander` (injected `snippetStore`), register the ⌥⌘E hotkey to `SnippetExpander.expand()`.

### Limitation (documented, honest scope)
AX selected-text read/replace works in native and most Cocoa text controls. Some apps (Chrome, and Electron-based apps such as VS Code, Slack) do not expose selected text via AX → those fall through to the beep (a safe no-op, never a crash or a clipboard side effect). This is inherent to the clipboard-free approach and is the accepted trade-off.

### Tests (`ClipnestCoreTests` + app-layer where possible)
- `SnippetStoreTests` / `SwiftDataSnippetStoreTests`: `findByKeyword` — exact match, case-insensitivity, trimming, no-match `nil`, newest-wins on duplicate keywords, empty/`nil`-keyword snippets never match.
- `SnippetExpander` logic with a mock `SelectedTextAccessing`: match → `replaceSelectedText` called with the body and `readSelectedText`'s result never sent to any clipboard; no match / nil selection → beep path, `replaceSelectedText` not called.
- Real AX read/replace and the global hotkey firing: manual-verify, flagged.

---

## Resolved decisions (from brainstorming)

- **A. Rich paste:** full approach — capture + store RTF, rich on Return, strip on ⌥Return. (Not "shortcut-only".)
- **B. Preview UI:** popover/tooltip anchored to the row (user note). Scope: images + truncated/multi-line text + files; skip short text.
- **C. No-match feedback:** system beep (`NSSound.beep()`). No toast this batch.
- **C. Expand hotkey:** ⌥⌘E default (rebindable later via the same `KeyboardShortcuts` recorder path as ⌥⌘V).
- **D. macOS Shortcuts:** deferred to v1.1.

## Open items for plan time

- Preview presentation mechanism (NSPopover vs transient child panel) — pick during implementation against the focus-retention constraint; whichever passes manual focus verification wins.
- Exact "truncated text" heuristic threshold (character count and/or newline presence) — tune during implementation.
