# Edit Copied Items — Design

Date: 2026-11-06 · Status: approved 2026-11-06 · Platforms: macOS + Linux (GTK)

## Intent

Users sometimes copy something, then want to fix or change it before reusing
it: correct a typo, trim it, reformat it. Today the only route is to paste it
somewhere, edit it there, and copy it again, which adds a second history entry.
This feature lets the user edit a history item in place, using a small popup
like the snippet editor, and save the result over the original entry.

## Goals

1. Every **text**, **rich text**, and **link** history item has an **Edit**
   action that opens a small editor popup styled like the existing snippet
   editor (`ClipnestApp/Sources/UI/Picker/SnippetEditorWindow.swift`,
   `Sources/ClipnestGTK/Window/SnippetEditorWindow.swift`).
2. The popup uses **one WYSIWYG rich-text editor for text, rich text, and
   links**, so they behave the same. The user can add formatting (bold, italic,
   underline, and so on) to plain text, and existing formatting on rich text
   loads and survives the round trip.
3. **Save replaces the existing entry.** It does not create a duplicate, and the
   original content is gone. **Cancel** changes nothing.
4. **Image items with OCR text** get an **Edit Recognized Text** action. It
   edits only the stored `ocrText`. The image itself is never changed.
5. Ships on **both macOS and Linux** in the same change, with matching
   behaviour.

## Non-goals

- Editing image pixels or file items. **No edit affordance of any kind**
  (button, menu entry, shortcut, accessibility action) appears for `.file`
  items, or for `.image` items that have no OCR text.
- Undo or version history of edits beyond what the editor's own in-session undo
  offers.
- Editing snippets (they already have their own editor).

## Anti-goals (failure even if it "works")

- Editing an item that is *not* on the system clipboard changes the clipboard.
- Writing the edited content to the clipboard creates a new history entry (the
  monitor must treat it as Clipnest's own write).
- An edit drops the formatting of a rich-text item that the user didn't touch.
- The edited item jumps position or loses its pin.
- A different-looking editor for plain text versus rich text.
- An edit affordance visible on files, or on images without OCR text.
- Blocking the main thread on blob I/O or hashing (project rule: only
  NSPasteboard access on main).
- A SwiftData schema change that crashes existing installs (new attributes must
  be optional or defaulted, with a backfill).

## Decided behaviour (user's decisions)

| Topic | Behaviour |
|---|---|
| Which kinds are editable | text, richText, link; image **only** its OCR text, and only when present |
| Save semantics | Replace the existing entry in place |
| Editor | One WYSIWYG rich-text editor for text, rich text, and links; same on both platforms |
| Platforms | macOS and Linux in the same change |
| Position / pin | Item keeps its list position, `pinned`, and `pinnedAt` |
| System clipboard | If the edited item is what's on the system clipboard right now, save also writes the edited content to the clipboard, so a normal paste gives the new version. If anything else is on the clipboard, it is not touched. That covers editing an older item, or the clipboard having changed since the edited item was copied. Either way, pasting from Clipnest gives the edited version. |
| Kind after edit | Plain text with no formatting added stays `.text`. Any formatting makes it `.richText`. A link whose result is still a single URL with no formatting stays `.link`, otherwise it becomes `.text` or `.richText` |
| Rich text with all formatting removed | Kind stays `.richText` (see Calls made) |
| Search | Finds the edited content, not the old content |
| Empty content | Save disabled, same validation as snippets |
| Formatting the editor can't represent | Warn before save: "Some formatting in this item can't be kept." User can save anyway or go back. Covers Linux (tables, lists, images, anything outside the GTK tag subset) and macOS (fonts normalized, attachments lost on the NSTextView round trip). If the item round-trips cleanly, no warning appears. |
| Edit matches another existing entry (same `contentHash`) | Merge: the edited entry stays in its spot, the other entry is deleted, and the merged entry is pinned if either was pinned (keep the earlier `pinnedAt`). Required because SQLite has a `UNIQUE` index on `content_hash` (`ClipItemsSchema.swift:91`); all stores behave the same. |

## Calls made (my choices, not confirmed by the user, but easy to change)

- **OCR editor:** uses the same popup but with the formatting toolbar hidden
  or disabled, because `ocrText` is stored as a plain `String`. Saving goes
  through the existing `ClipStore.setRecognizedText(_:text:)`.
- **Entry points:** they mirror `SnippetRow` and `ItemRow`. The item row gets a
  pencil `ExpandingIconButton` on hover, an **Edit** (or **Edit Recognized
  Text**) entry in the context menu, and a named VoiceOver/AT custom action.
  On Linux they go into `ItemRowActionContent`'s shared action list, so the
  buttons and context menu stay in sync. A keyboard shortcut is **optional**:
  the builder may add one if a free chord exists in
  `PickerWindow+Keyboard.swift` and the macOS picker, but must not reassign an
  existing one.
- **Rich text with all formatting removed stays `.richText`**, so a round trip
  never surprises the user by changing an item's icon or kind.
- **Link rule:** the kind after an edit uses the same `isLink(_:)` check that
  capture uses (`PasteboardReader.swift:515`), so capture and edit never
  disagree. If a link gets formatting, it becomes `.richText`, its
  `previewText` holds the visible text, and the link-only row UI goes away.
- **Hash, preview, and size:** computed with exactly the same code that
  capture uses (same hash scheme, same `previewText` truncation or flattening,
  same `byteSize` meaning). Refactor that code into a shared helper rather
  than copying it. An edited item is indistinguishable from a fresh capture
  of the same content.
- **Lossy detection:** compare the item's stored representation with what the
  editor would write back for the *unedited* content. If anything is lost, the
  warning shows on save. The Linux editor supports a defined subset (at least
  b/i/u, color, and font family/size), parsed from and written to the bundle's
  HTML. On save, every representation in the `LinuxRichTextBundle` is
  regenerated from the editor content, so no stale RTF sits next to new HTML.
  Legacy flat-HTML blobs are read, and saved back as a bundle.
- **"On the clipboard" check:** done at save time, not when the popup opens.
  The edited item counts as on the clipboard when the current clipboard
  content hashes to the item's *pre-edit* `contentHash`, using the capture
  hash scheme. Only that clipboard read runs on main; hashing runs off-main.
  The write reuses the existing `Paster` write paths (`.text`, `.richText`)
  and the monitor's existing self-write suppression (see
  `ClipboardMonitor.swift` around line 543), so the write never shows up as a
  new history entry. On Linux, use the existing
  `LinuxClipboardSelectionReplacer` / `GTKClipboardWriting`. Only the
  CLIPBOARD selection is involved, not PRIMARY.
- **Item gone while editing** (retention eviction, Clear History, delete): the
  save fails with an inline message ("This item no longer exists."), the
  popup stays open, and the user can copy the text out. Nothing is
  re-inserted.
- **Blob cleanup:** the old blob is deleted only when no other item
  references that path or hash after the update (blobs are
  content-addressed, so they can be shared).
- **GTK popup:** extend or share chrome with the existing GTK
  `SnippetEditorWindow`, and add the formatting toolbar. Use only `GtkTextTag`
  features available in the GTK version the project already targets.
- **`createdAt` is unchanged** (that is what preserves the position).
- **Picker state:** while the editor popup is open, the picker stays open (or
  re-opens to the same selection), the same way the snippet editor works today.

## Constraints and where things live

- **Model:** `Sources/ClipnestCore/Model/ClipItem.swift`. The editable fields
  are `previewText` (full content for `.text`/`.link`, plain flattening for
  `.richText`), `contentHash`, `byteSize`, `kind`, and `blobPath` (the RTF
  blob for `.richText`).
- **Store protocol:** `Sources/ClipnestCore/Store/ClipStore.swift`. Add one
  method that replaces an item's content (something like
  `updateContent(_ id: UUID, kind:, previewText:, contentHash:, byteSize:, blobPath:)`).
  It must be implemented in every store:
  `InMemory…`, `Platform/macOS/SwiftData…`, and `ClipnestSQLite`. Add a case
  to the store contract tests (`Tests/ClipnestCoreTests/*ContractTests*`).
  Keep `pinned`, `pinnedAt`, `createdAt`, the source app fields, and `ocrText`
  as they are.
- **Blobs:** new RTF bytes go through `BlobStore` (content-addressed by hash).
  An old blob that is no longer referenced is deleted with the existing
  `deleteBlobs(for:using:)` path, and only after the store update succeeds.
  All blob I/O and hashing runs off the main thread.
- **Rich text formats:** macOS stores RTF (`Paster.swift`'s
  `.richText(rtf:plain:)`, `MacRichTextFlattener`). Linux uses
  `LinuxRichTextBundle` (`Sources/ClipnestPlatformLinux/Clipboard/`). The
  editor must load from, and save back to, each platform's existing stored
  representation. Paste must work unchanged on the edited item.
- **Editors:** macOS can use an `NSTextView` with rich text enabled, wrapped for
  SwiftUI, plus a small formatting toolbar. GTK can use a `GtkTextView` with
  text tags, plus the matching toolbar. The two toolbars should offer the same
  set of formatting controls. The minimum set is bold, italic, and underline;
  the builder may add more if both platforms support it.
- **Gating:** add a single `ClipItem` predicate (next to the existing
  `supportsSaveAsSnippet`), such as `supportsContentEdit` /
  `supportsRecognizedTextEdit`. Both platforms' UI reads it, so the "no edit on
  files or images" rule lives in one place (DRY rule in
  `.claude/coding-standards.md`).
- **Shared view-model logic** (kind resolution after edit, validation) belongs in
  `Sources/ClipnestViewModels/` so both platforms use the same code, with unit
  tests.
- **Persistence:** no new SwiftData attributes are expected. If one turns out
  to be needed, it must be optional or defaulted, with a backfill.
- **Docs:** README and user docs describe the feature in the same change, along
  with any in-code comment that says items are immutable.

## Left to the builder

- The exact name and signature of the store method, and the kind-resolution
  helper.
- The toolbar layout and the exact formatting controls, beyond the minimum set.
- The popup size, and whether it reuses `SnippetEditorWindow`'s chrome directly
  or through a shared base.
- How the picker refreshes after a save (the existing reconcile/refresh paths).

## Acceptance criteria

1. Text, rich text, and link rows show Edit in the hover actions, the context
   menu, and the accessibility actions, on both platforms. File rows show none.
   Image rows show Edit Recognized Text only when `ocrText` is non-empty.
2. Editing a plain-text item, adding bold to one word, and saving results in an
   item of kind `.richText` that pastes with the bold intact.
3. Editing a rich-text item, changing only one word, and saving keeps all
   other formatting the editor supports. If the item had formatting the editor
   can't represent, the "Some formatting in this item can't be kept." warning
   appears before saving. No warning appears when nothing is lost.
11. Editing an item so that it matches another entry merges them: one entry
    remains in the edited item's position, pinned if either was pinned, and
    the history count drops by one. All three stores behave the same.
12. Saving after the item was deleted shows "This item no longer exists." and
    writes nothing.
4. After saving, the item keeps its list position and pin state, and the
   history count is unchanged.
5. Copy X and edit X: after save, the system clipboard holds the edited X
   (rich formatting included) and no extra history entry appears. Copy X,
   copy Y, then edit X: the clipboard still holds Y, unchanged. Open Edit on X
   (on the clipboard), copy Y mid-edit (Y is captured normally), paste Y into
   the editor, then save: X holds the edited text, the clipboard stays Y, and
   Y's history entry is untouched.
6. Searching for the new text finds the item, and searching for removed text
   does not.
7. Save is disabled when the content is empty or whitespace only.
8. Cancel leaves the item byte-identical.
9. Editing OCR text changes what search finds and what Copy Recognized Text
   gives, and leaves the image blob untouched.
10. The store contract tests pass for the in-memory, SwiftData, and SQLite
    stores. Kind resolution has unit tests.
