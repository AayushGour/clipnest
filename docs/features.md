# Clipnest — Feature implementation guide

A developer-facing walkthrough of *how* each Clipnest feature is actually
built, with `file:line` references into the current source tree. This
complements [`docs/API.md`](API.md) (the `ClipnestCore` API surface) — this
document instead follows each feature end-to-end through its real control
flow, across both `ClipnestCore` (`Sources/ClipnestCore/`) and the app shell
(`ClipnestApp/Sources/`).

All line numbers are as of the current `main` and will drift as the code
changes — treat them as pointers, not permanent anchors.

## Contents

1. [Clipboard capture](#1-clipboard-capture)
2. [Content classification](#2-content-classification)
3. [Privacy filtering](#3-privacy-filtering)
4. [Deduplication](#4-deduplication)
5. [Persistence](#5-persistence)
6. [Search](#6-search)
7. [The picker UI](#7-the-picker-ui)
8. [Paste / insertion](#8-paste--insertion)
9. [Snippets](#9-snippets)
10. [Global hotkey](#10-global-hotkey)
11. [Permissions](#11-permissions)
12. [App lifecycle & DI](#12-app-lifecycle--di)
13. [Testing strategy](#testing-strategy)

---

## 1. Clipboard capture

**What it does.** Polls the system pasteboard roughly every 0.4s; when its
contents changed, classifies and stores the new item — unless privacy rules
or the write is Clipnest's own.

**Key files**
- `Sources/ClipnestCore/Clipboard/ClipboardMonitor.swift:54-280` — the monitor itself
- `Sources/ClipnestCore/Clipboard/ClipboardMonitor.swift:33-37` — `MonitoredPasteboard` (pasteboard abstraction)
- `Sources/ClipnestCore/Clipboard/ClipboardMonitor.swift:12-28` — `FrontmostApplicationProviding` (capture-source attribution)

**How it works.**
`ClipboardMonitor` is a `@MainActor final class` (`ClipboardMonitor.swift:54`)
holding `lastChangeCount: Int` (`:96`), seeded from `pasteboard.changeCount`
at `init` (`:144`). `start()` (`:148-158`) schedules a repeating
`Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true)` whose
callback hops into a `Task { @MainActor in ... }` and calls `checkNow()`.
`pollInterval` defaults to `ClipboardMonitor.defaultPollInterval = 0.4`
seconds (`:56-57`) — chosen because macOS has no push notification for
pasteboard changes, balancing responsiveness against CPU wake-ups. `stop()`
(`:161-164`) invalidates the timer.

`checkNow()` (`:201-279`) is the actual check-and-capture cycle, and is also
called directly and synchronously by tests instead of waiting on a real
`Timer`:
1. Read `pasteboard.changeCount`; if it equals `lastChangeCount`, return
   `nil` — nothing changed (`:203-205`).
2. Advance `lastChangeCount` to the new value immediately (`:205`) — happens
   *before* any privacy/self-write check, so a rejected or ignored change is
   never re-evaluated on the next poll.
3. If the new `changeCount` matches a pending `ignoredChangeCount` (see
   below), clear it and return `nil` (`:207-210`) — this is a self-write,
   not a real external copy.
4. Read the frontmost app's bundle ID/name via
   `frontmostApplicationProvider` (`:212-213`), then ask `PrivacyFilter
   .shouldCapture(...)` whether to proceed (`:215-224`; see [§3](#3-privacy-filtering)).
5. Classify via `reader.read(from: pasteboard)` (`:226`; see [§2](#2-content-classification)).
6. Write any raw payload bytes to `BlobStore` (`:228-250`) and build the
   `ClipItem` (`:252-266`). The blob write itself runs **off the `@MainActor`**:
   `blobStore.write(rawData)` is dispatched onto `Task.detached(priority:
   .utility)` and awaited via `.value`, with the `Sendable` `BlobStore`
   copied into a local `let` first so the closure captures the value, not
   `self` (`:237-240`) — the same off-main disk-I/O pattern already used for
   blob *reads* in `ItemPreview.swift`/`ItemRow.swift`. Behavior is
   unchanged from a synchronous write: the blob still lands on disk before
   the store insert, and a write failure still aborts the capture the same
   way (see below).
7. Persist via `store.insertOrBumpDuplicate(item)` (`:269`; see
   [§4](#4-deduplication)), then invoke `onCapture(stored)` (`:270`).

**Self-write suppression.** `ignore(changeCount:)` (`:192-194`) records a
`changeCount` that Clipnest itself just produced (e.g.
`PickerViewModel`'s copy-on-select paste, wired in `AppEnvironment.swift:222-224`)
so the *next* `checkNow()` that observes exactly that `changeCount`
short-circuits at step 3 above instead of recapturing Clipnest's own write as
a new external copy. Only one ignored value is tracked at a time —
last-recorded wins (`:189-191`).

**Lifecycle.** `pause()`/`resume()` (`:168-175`) toggle `isPaused`, checked
inside `PrivacyFilter.shouldCapture` (unconditional reject while paused —
see [§3](#3-privacy-filtering)). `checkNow()` still advances `lastChangeCount`
while paused, so resuming doesn't immediately recapture whatever changed
during the pause (`:166-167` doc comment). `AppEnvironment` also uses
`pause()`/`ignore(changeCount:)`/`resume()` together to suppress capture
during the snippet-expander's clipboard-borrowing fallback
(`AppEnvironment.swift:243-247`).

**Live picker updates.** `onCapture: (ClipItem) -> Void` (`:121`) is wired by
`AppEnvironment` to `PickerViewModel.handleNewCapture()`
(`AppEnvironment.swift:234-236`) so a live capture pushes a bounded
page-0 requery into the picker instead of the picker itself polling the
store on a timer (see [§7](#7-the-picker-ui)).

**Failure handling.** `CaptureFailureHandler` (`:45`) receives thrown errors
(blob-write failure or store failure) and, by default,
`logCaptureFailure(_:)` (`:68-83`) logs only the error's *kind* (never
clipboard content) via `os.Logger`.

**Edge cases handled**
- Pasteboard unchanged since last poll → no-op (`:203-205`).
- Self-write (picker paste, snippet-expander clipboard borrow) → ignored via `ignoredChangeCount`.
- Concealed/transient/paused/excluded-app changes → rejected by `PrivacyFilter` before any classification happens.
- Nothing classifiable on the pasteboard → `reader.read` returns `nil`, no-op.
- Blob write failure → capture aborted for that cycle rather than storing a dangling `blobPath` (`:229-250`).
- Store failure → surfaced via `captureFailureHandler`, never silently swallowed.

**Tests.** `Tests/ClipnestCoreTests/ClipboardMonitorTests.swift` — e.g.
`checkNow captures exactly one ClipItem on an accepted change` (`:123`),
`onCapture fires with the stored item after a successful capture (T51)` (`:147`),
`checkNow is a no-op when the pasteboard hasn't changed` (`:193`),
`While paused, no changes are captured even though the pasteboard changed` (`:220`),
`resume() allows capture again after pause()` (`:236`),
`Consecutive identical copies dedup through the monitor` (`:304`),
`Capturing an image writes its bytes to BlobStore and sets a valid blobPath + byteSize` (`:327`).

**Gotchas / constraints**
- `checkNow()` must be called on `@MainActor`; production capture is driven
  entirely by the `Timer`, but tests drive it deterministically and
  synchronously — no real `Timer` in `ClipnestCoreTests` (repo testing rule).
- `lastChangeCount` advances even for a *rejected* change (privacy-filtered
  or self-write) — that change is permanently skipped, not retried.

---

## 2. Content classification

**What it does.** Turns the pasteboard's current representations into one of
five `ItemKind`s, with a preview string, a stable content hash, byte size,
and (for image/richText) raw bytes for `BlobStore`.

**Key files**
- `Sources/ClipnestCore/Clipboard/PasteboardReader.swift:26-206` — `PasteboardReader` and `Classification`
- `Sources/ClipnestCore/Model/ItemKind.swift:8-14` — the five kinds

**How it works.**
`PasteboardReader.read(from:)` (`PasteboardReader.swift:84-104`) checks
pasteboard types in a fixed, most-specific-first priority order, because a
single pasteboard change commonly carries several representations at once
(a Finder file copy often also carries a `.tiff` thumbnail and/or a
plain-text path; a browser image copy often also carries a `.string` URL):

1. `.fileURL` → `readFile(_:)` (`:87-89`, `:137-153`) → `.file`. `byteSize`
   is deliberately `0` here — `attributesOfItem` (a `stat`) used to run
   synchronously on the main-thread capture path and froze the app for
   iCloud/dataless or TCC-gated files; the real size is now read later,
   off-main-thread, only when a preview needs it (`ItemPreview.swift`'s
   `FilePreview`, `:204-213`).
2. Image (`.tiff` then `.png`, `:64-68`, `:106-114`) → `readImage(_:)`
   (`:116-124`) → `.image`. Both types are checked because different apps
   offer different representations (Preview → `.tiff`; many web/image apps →
   `.png`).
3. `.rtf` → `readRichText(_:from:)` (`:155-167`) → `.richText`. Preview text
   prefers the pasteboard's own `.string` representation when present,
   falling back to `NSAttributedString(data:options:[.documentType: .rtf])`
   parsing, then `"Rich Text"` as a last resort (`:169-183`).
4. `.string` → `readPlainText(_:)` (`:185-195`) → `.text` or `.link`.

**Link detection** (`isLink(_:)`, `:197-205`): trimmed text must be
non-empty, contain no whitespace, parse as a `URL` with a scheme in
`{http, https, ftp, mailto}` (`:62`), and (for non-`mailto` schemes) have a
non-empty host.

**Content hash.** Every branch computes `contentHash` via
`BlobStore.contentHash(of:)` (SHA256-hex, `BlobStore.swift:66-68`) — the
*same* algorithm `BlobStore.write(_:)` uses for its content-addressed
filenames, deliberately consolidated into one place. `.file` hashes the
*URL string*, not file bytes (`:149`); every other kind hashes its actual
content bytes.

**Raw data.** Only `.image` and `.richText` populate `Classification
.rawData` (`:37-59` doc comment) — those are the kinds whose bytes get
written to `BlobStore`. `PasteboardReader` never touches `BlobStore` itself;
it's a pure, I/O-free classifier — `ClipboardMonitor` owns the actual
blob write, off-main via `Task.detached` (`ClipboardMonitor.swift:228-250`),
keeping "classify" and "persist" as separate, independently-testable
responsibilities.

**Edge cases handled**
- Multiple simultaneous representations → most-specific type wins (file over image over rich text over plain string).
- A plain string that isn't a valid/host-bearing URL → `.text`, not `.link` (`:120` test, `:197-205`).
- A `.richText` payload whose plain-text fallback also fails to parse → previewText `"Rich Text"`.
- A file reference to a path that no longer exists → still classifies as `.file` with `byteSize: 0` (`:225` test).
- No supported type present at all → `read(from:)` returns `nil`.

**Tests.** `Tests/ClipnestCoreTests/PasteboardReaderTests.swift` — e.g.
`Classifies plain text as .text` (`:27`), `Classifies a URL string as .link` (`:41`),
`Classifies RTF data as .richText` (`:54`), `An image is classified as .image
even when a .string representation is also present` (`:162`),
`A file reference is classified as .file even when an image thumbnail type is
also present` (`:206`), `A file reference to a nonexistent path still
classifies, with byteSize 0` (`:225`).

**Gotchas / constraints**
- `PasteboardReader` has zero `BlobStore` dependency by design — don't add
  one; blob writes belong in `ClipboardMonitor`.
- `.file`'s `byteSize` is always `0` at capture time — never assume it's the
  real file size without a later, off-main-thread stat.

---

## 3. Privacy filtering

**What it does.** Decides, before anything is classified or stored, whether
a pasteboard change should be captured at all — rejecting password-manager
apps and any content explicitly marked concealed/transient, unconditionally.

**Key files**
- `Sources/ClipnestCore/Clipboard/PrivacyFilter.swift:10-70`

**How it works.**
`PrivacyFilter.shouldCapture(availableTypes:sourceBundleID:isPaused
:customExcludedBundleIDs:)` (`:46-69`) runs four checks in a fixed order,
with the first two being **unbypassable** — no parameter combination can
skip them:

1. `availableTypes` contains `org.nspasteboard.ConcealedType` or
   `org.nspasteboard.TransientType` (the two constants defined at `:27-33`,
   the community `org.nspasteboard` convention password managers/OTP tools
   set) → reject, unconditionally (`:52-58`).
2. `isPaused` → reject (`:60`).
3. `sourceBundleID` is in `PrivacyFilter.builtInExcludedBundleIDs` (`:15-22`
   — 1Password 7/8, Bitwarden, LastPass, Dashlane, Keeper) **union**
   `customExcludedBundleIDs` (a caller-supplied additive list, e.g. from a
   future Settings screen) → reject (`:62-66`).
4. Otherwise → accept (`:68`).

`customExcludedBundleIDs` can only ever *add* exclusions — there's no
parameter that removes the built-in list or the concealed/transient check
(doc comment, `:43-45`).

**Edge cases handled**
- Concealed/transient marker present *and* not paused *and* not from an excluded app → still rejected (unconditional check wins).
- `sourceBundleID == nil` (frontmost app unknown) → passes the app-exclusion check by default (can't match a set membership against `nil`).
- Custom excluded list is empty → built-in list alone still applies.

**Tests.** `Tests/ClipnestCoreTests/PrivacyFilterTests.swift` — e.g.
`Accepts a normal capture from a non-excluded app` (`:12`), `Rejects
unconditionally when the concealed marker is present` (`:25`), `Rejects
everything while paused` (`:69`), `Rejects a built-in password-manager bundle
ID` (`:82`), `Rejects a caller-supplied custom excluded bundle ID` (`:95`).

**Gotchas / constraints**
- This is called *before* `PasteboardReader.read(from:)` in
  `ClipboardMonitor.checkNow()` (`ClipboardMonitor.swift:215-226`) — a
  rejected change is never classified or hashed, so no content from a
  privacy-filtered app is ever even briefly held in memory as a `ClipItem`.
- Bundle-ID list is verified/hardcoded, not user-visible/editable yet beyond
  the `customExcludedBundleIDs` injection point.

---

## 4. Deduplication

**What it does.** Copying content that's already in history doesn't create a
second row — it bumps the existing row's timestamp back to "now" instead.

**Key files**
- `Sources/ClipnestCore/Store/ClipStore.swift:36-40` — protocol contract
- `Sources/ClipnestCore/Store/InMemoryClipStore.swift:22-32`
- `Sources/ClipnestCore/Store/SwiftDataClipStore.swift:185-199`

**How it works.**
Every capture computes a `contentHash` at classification time (see
[§2](#2-content-classification)). `insertOrBumpDuplicate(_ item:)` is the
sole write path a fresh capture goes through
(`ClipboardMonitor.swift:269`):
- **`InMemoryClipStore`** (`InMemoryClipStore.swift:22-32`): scans
  `itemsByID.values` for an existing item with the same `contentHash`
  (`:23`); if found, copies it, overwrites only `createdAt` with the
  incoming item's `createdAt`, and writes it back under its *original* id
  — every other field (in particular `pinned`) is preserved, not
  overwritten by the incoming duplicate's fields. If not found, inserts the
  new item under its own id.
- **`SwiftDataClipStore`** (`SwiftDataClipStore.swift:185-199`): fetches a
  `ClipItemRecord` with a matching `contentHash` predicate
  (`fetchRecord(contentHash:)`, `:304-309`); on a hit, mutates `existing
  .createdAt = item.createdAt` in place and saves — same "bump `createdAt`
  only, preserve everything else" rule, explicitly called out in the doc
  comment (`:187-189`) as matching `InMemoryClipStore`'s behavior exactly.

Because `createdAt` drives the History tab's sort order (`ClipScope
.history`, newest-first), bumping it moves the duplicate back to the top of
history — "collapse and resurface," not "collapse and vanish."

**Edge cases handled**
- Re-copying a currently-pinned item → `createdAt` bumps but `pinned`/`pinnedAt` are untouched (dedup never affects pin state).
- Two genuinely distinct items with different `contentHash`es always coexist as separate rows.
- Rapid identical re-copies (monitor-level) → each `checkNow()` cycle still dedups correctly (`ClipboardMonitorTests.swift:304`).

**Tests.** `Tests/ClipnestCoreTests/ClipStoreTests.swift:36` /
`Tests/ClipnestCoreTests/SwiftDataClipStoreTests.swift:62` — both titled
"Inserting the same contentHash twice collapses to one row and bumps
createdAt"; `Distinct contentHashes both stay in the store` (both files);
`ClipboardMonitorTests.swift:304` — "Consecutive identical copies dedup
through the monitor".

**Gotchas / constraints**
- Dedup key is `contentHash`, not `id` — two `ClipItem`s can have different
  `id`s but the same `contentHash` only transiently, during the moment
  `insertOrBumpDuplicate` is resolving them; the store never persists two
  rows with the same hash.
- `.file`'s `contentHash` is derived from its *URL string*, not file bytes
  (see [§2](#2-content-classification)) — copying the same file reference twice dedups; copying two
  different files with identical byte content does **not** (they hash to
  different URL strings).

---

## 5. Persistence

**What it does.** Durable, on-disk storage for clipboard history and
snippets (SwiftData), plus content-addressed disk storage for large payloads
(`BlobStore`), plus configurable retention that never touches pinned items.

**Key files**
- `Sources/ClipnestCore/Store/SwiftDataClipStore.swift` (whole file — store + private `ClipItemRecord` `@Model`)
- `Sources/ClipnestCore/Store/SwiftDataSnippetStore.swift` (whole file — store + private `SnippetRecord` `@Model`)
- `Sources/ClipnestCore/Store/BlobStore.swift:24-131`
- `Sources/ClipnestCore/Store/ClipStore.swift:9-20` (`RetentionCap`), `:97-110` (`deleteBlobs`)
- `Sources/ClipnestCore/Store/InMemoryClipStore.swift` / `InMemorySnippetStore.swift` — canonical test doubles

**How it works — SwiftData confinement.**
Per the project's decision D6, `ClipItem`/`Snippet` are plain `Sendable`
value types, never SwiftData types. `SwiftDataClipStore` is a plain `actor`
(not the `@ModelActor` macro, so its `init` can also accept the shared
`BlobStore` — `SwiftDataClipStore.swift:13-21`) that owns a **private**
`@Model` class, `ClipItemRecord` (`:362-473`, file-private — never referenced
outside this file), and maps to/from `ClipItem` on every call via
`ClipItemRecord.init(_:)` (`:433-449`) and `asClipItem()` (`:457-472`).
`SwiftDataSnippetStore`/`SnippetRecord` mirror this shape exactly
(`SwiftDataSnippetStore.swift:9-24`, `:251-298`). A SwiftData type never
crosses either protocol boundary.

Production containers live at `~/Library/Application
Support/Clipnest/ClipItems.store` and `.../Snippets.store`
(`SwiftDataClipStore.swift:48-68`, `SwiftDataSnippetStore.swift:28-49`) — the
same base directory family as `BlobStore.defaultBaseDirectory()`
(`BlobStore.swift:52-58`). `makeTestContainer()` builds a plain in-memory
`ModelConfiguration(schema:isStoredInMemoryOnly: true)` against an
**explicit `Schema`** — not a temp file (`SwiftDataClipStore.swift:75-90`,
mirrored at `SwiftDataSnippetStore.swift:54-65`). The explicit `Schema` is
what keeps SwiftData from inferring the model (and a store name) from
`Bundle.main`; the older "Unable to determine Bundle Name" crash that made
in-memory containers unsafe for a hostless SwiftPM test bundle was specific
to Xcode 16.2, and CI's `swift test` step already runs on Xcode 26 (see
`docs/architecture.md`'s CI section), so that workaround is no longer needed
here. `makeContainerForTesting(at:)`
(`SwiftDataClipStore.swift:98-108`, mirrored at `SwiftDataSnippetStore.swift:70-80`)
is unchanged and still builds a real on-disk container at an explicit
temp-file `url` — not to dodge a toolchain bug, but because its migration
tests specifically need a genuine store file to prove an in-place SwiftData
migration.

**How it works — the migration-safety pattern (`normalizedText`).**
`ClipItemRecord.normalizedText` (`SwiftDataClipStore.swift:368-393`) and
`SnippetRecord.normalizedText` (`SwiftDataSnippetStore.swift:257-274`) are
each a derived, lowercased index field (`previewText.lowercased()`, or
`(title + " " + body).lowercased()`) that `query(...)`'s `#Predicate` uses
for a case-insensitive substring match — SwiftData predicates can't call
`.lowercased()` inline, so the lowercase form is precomputed and stored.

**This is the concrete pattern to follow for any new non-optional `@Model`
attribute:**
- The attribute **must** carry a default value (`var normalizedText: String
  = ""`) when added after a `@Model` type's first release. SwiftData's
  lightweight migration only auto-migrates a new *non-optional* attribute if
  it has a default to backfill existing on-disk rows with — exactly Core
  Data's lightweight-migration rule (a new required attribute must be
  optional *or* defaulted).
- **Shipping without the default crashes launch** for every user with an
  existing on-disk store: `ModelContainer` construction throws
  `NSCocoaErrorDomain` **134110** — "Cannot migrate store in-place: ...
  missing attribute values on mandatory destination attribute." That throw
  propagates out of `SwiftDataClipStore.makeProductionContainer()`
  (`:53-68`) → `AppEnvironment.init()` (`AppEnvironment.swift:76-90`, itself
  `throws`) → `AppDelegate.applicationDidFinishLaunching`
  (`AppDelegate.swift:22-38`), which catches it and calls
  `NSApplication.shared.terminate(nil)` — i.e. the app quits on every launch
  until fixed. (Additive **optional** fields, like `ClipItemRecord.pinnedAt`
  at `:396`, don't need this — SwiftData defaults a new optional to `nil`
  automatically.)
- The default alone only makes migration *succeed* — every row that
  migrates in still has `normalizedText == ""` (unsearchable) until
  repaired. Each store's `init` therefore runs a **one-time backfill**
  before assigning `self.modelContext` (`SwiftDataClipStore.swift:41`,
  `SwiftDataSnippetStore.swift:22`):
  `backfillNormalizedText(in:)` (`SwiftDataClipStore.swift:155-181`,
  `SwiftDataSnippetStore.swift:118-144`) fetches every record where
  `normalizedText == "" && previewText != ""` (or title/body non-empty for
  snippets), recomputes `normalizedText` for each, and saves. It runs on
  *every* `init`, but after the first launch backfills everything, the
  predicate matches nothing on every later launch — a cheap "fetch nothing"
  call, no separate "have I migrated" flag needed. Failures here are logged
  (metadata only) and swallowed, never thrown — there's no safe fallback
  mid-`init`.
- `#Index`/`#Unique` on `normalizedText` was considered to speed up
  `query(...)`'s predicate scans but skipped: those macros require macOS
  15+, and the deployment target is macOS 14 — `FetchDescriptor
  .fetchOffset`/`fetchLimit` bound scan cost instead (doc comments at
  `ClipItemRecord`'s top, `:356-361`).

**How it works — `BlobStore`.** Content-addressed disk storage for payloads
too large for `ClipStore`'s metadata-only records (`BlobStore.swift:24-44`).
- **Write** (`:80-96`): `blobPath = "blobs/\(contentHash(of: data))"`;
  if a file already exists at that path, returns the existing path
  immediately (`:84-86`) — writing identical bytes twice is a cheap no-op,
  never a second file. Otherwise creates the `blobs/` directory and writes
  atomically.
- **Read** (`:100-110`): throws `BlobStoreError.notFound` if the path
  doesn't exist.
- **Delete** (`:121-129`): **idempotent** — a missing path returns normally
  rather than throwing, deliberately unlike `read` (a missing `blobPath`
  during cleanup isn't a genuine failure — the blob may already be gone;
  behaves like `rm -f`).
- **Dedup + hashing**: `BlobStore.contentHash(of:)` (`:66-68`, SHA256-hex)
  is the single hashing implementation shared with
  `PasteboardReader`'s `ClipItem.contentHash` (see [§2](#2-content-classification)) — one place,
  per the project's DRY rule.
- `baseDirectory` is always injected, never hardcoded in any read/write/
  delete path (`:20-23`), so tests point it at a throwaway temp directory
  and the real container is only reached via `defaultBaseDirectory()`
  (`:52-58`), which every production caller shares.

**How it works — blob/store cleanup.** `deleteBlobs(for:using:)`
(`ClipStore.swift:97-110`) is a free function shared by every `ClipStore`
implementation: it best-effort-deletes every blob referenced by a list of
items, collecting individual failures instead of aborting mid-cleanup, then
throws one summarizing `ClipStoreError.ioFailure` if any failed. Both
`InMemoryClipStore.delete`/`clearHistory`/`enforceRetention`
(`InMemoryClipStore.swift:82-101`) and `SwiftDataClipStore`'s equivalents
(`SwiftDataClipStore.swift:253-293`) call it after removing rows.

**How it works — retention.** `RetentionCap` (`ClipStore.swift:15-20`) is
`.maxCount(Int)` or `.maxAge(TimeInterval)`; `nil` (the default everywhere
it's used) means "keep everything," matching the spec. `enforceRetention
(cap:)`:
- `InMemoryClipStore.swift:93-118` — `idsExceedingCap(_:)` (`:106-118`)
  filters to `!$0.pinned` first, then for `.maxCount` sorts oldest-first and
  takes the excess; for `.maxAge` filters to `createdAt < cutoff`.
- `SwiftDataClipStore.swift:269-293` — same two branches expressed as
  `#Predicate`s scoped to `pinned == false`.

**Pinned-item protection** is structural, not a bolt-on check: both
implementations only ever build their candidate-for-deletion set from
`pinned == false` items — a pinned item is never even considered, regardless
of `cap`.

**Edge cases handled**
- `cap == nil` → `enforceRetention` is a complete no-op, no matter how much history has accumulated.
- Count cap already satisfied → no-op.
- Every candidate for trimming has its blob deleted too (`deleteBlobs`).
- Deleting an item that has no blob (`blobPath == nil`) never touches `BlobStore`.
- A record persisted with empty `normalizedText` (simulating pre-migration data) becomes matchable again after the next store `init`.
- A real pre-`normalizedText` on-disk store file migrates in place without throwing.

**Tests.**
`Tests/ClipnestCoreTests/BlobStoreTests.swift` — round-trip, dedup-on-write,
idempotent delete, `.notFound` on missing read.
`Tests/ClipnestCoreTests/ClipStoreTests.swift` and
`SwiftDataClipStoreTests.swift` (parallel suites, `.serialized` on the
SwiftData one) — dedup, pin/unpin, delete+blob cleanup, `clearHistory`,
`enforceRetention` (`.maxCount`/`.maxAge`, pinned-exclusion), `query`
filtering. Migration-specific: `SwiftDataClipStoreTests.swift:546` "A record
persisted with empty normalizedText ... is backfilled by init and becomes
matchable by query" and `:568` "A store file written before normalizedText
existed migrates in-place without throwing ... and the migrated row is
backfilled and matchable" (constructs a *real* pre-fix on-disk store file via
a test-local legacy `ClipItemRecord` schema and reopens it with the current
schema — a genuine Core Data lightweight migration, not just a same-schema
reopen). `SwiftDataSnippetStoreTests.swift:272`/`:293` mirror these for
snippets.

**Gotchas / constraints**
- Any future non-optional `@Model` attribute added to `ClipItemRecord`/
  `SnippetRecord` **must** ship with a default value, or every existing
  user's app will crash on next launch (134110). Optional attributes don't
  need this.
- `ClipItemRecord`/`SnippetRecord` are `private` to their files — test code
  can only construct/inspect them through the explicit test-only factory
  methods each store exposes (`makeTestContainer`, `makeContainerForTesting
  (at:)`, `insertRecordWithEmptyNormalizedTextForTesting`).
- No `#Index`/`#Unique` on the query-relevant fields — deployment target
  (macOS 14) predates those macros; don't add them without also raising the
  target (a logged architect decision per coding-standards.md).

---

## 6. Search

**What it does.** Filters/sorts/paginates clipboard history and snippets
entirely inside the store (not client-side), and separately highlights match
ranges for on-screen display.

**Key files**
- `Sources/ClipnestCore/Search/SearchQuery.swift:9-17`
- `Sources/ClipnestCore/Search/SearchHighlighter.swift:11-32`
- `Sources/ClipnestCore/Store/ClipStore.swift:55-67` (`query` contract)
- `Sources/ClipnestCore/Store/SnippetStore.swift:32-38` (`query` contract)
- `Sources/ClipnestCore/Store/SwiftDataClipStore.swift:217-241`
- `Sources/ClipnestCore/Store/SwiftDataSnippetStore.swift:182-193`

**How it works — matching semantics.**
`ClipStore.query(text:kind:scope:offset:limit:)`
(`ClipStore.swift:65-67`, implemented at `SwiftDataClipStore.swift:217-241`
and `InMemoryClipStore.swift:45-70`):
- `scope` selects `.history` (`pinned == false`, sorted `createdAt`
  descending) or `.pinned` (`pinned == true`, sorted `pinnedAt` ascending —
  earliest-pinned first).
- `text` is a case-insensitive **substring** match against `previewText`
  (via the precomputed `normalizedText` in the SwiftData store — see
  [§5](#5-persistence)); empty text matches everything.
- `kind` is an exact `ItemKind` match when non-nil; `nil` matches every kind.
- `text` and `kind` combine with **AND** (`SwiftDataClipStore.swift:226-230`
  — both conditions in one `#Predicate`).
- `offset`/`limit` window the already-filtered-and-sorted result
  (`FetchDescriptor.fetchOffset`/`fetchLimit`, `:238-239`).

`SnippetStore.query(text:offset:limit:)`
(`SnippetStore.swift:32-38`, `SwiftDataSnippetStore.swift:182-193`) matches
`text` case-insensitively against `title` **OR** `body` (not AND — either is
enough); `keyword` is never checked by `query` (the picker's form has no
control for it — see [§9](#9-snippets)).

`fetchAll(matching:)` (`ClipStore.swift:42-49`) is intentionally unbounded
and ignores its `query:` parameter entirely — kept only for source
compatibility with older callers/tests. All real, user-facing filtering
goes through `query(...)`.

**How it works — highlighting.**
`SearchHighlighter.matchRanges(in:matching:)`
(`SearchHighlighter.swift:18-31`) is a pure, UI-free function: repeatedly
calls `text.range(of: query, options: [.caseInsensitive], range:...)`,
advancing `searchStart` to each match's `upperBound` so matches are
**non-overlapping** (e.g. `"ababab"` matched against `"ab"` yields three
ranges, not overlapping ones starting at every `"a"`). Returns `[]` for an
empty query or no match. The App layer
(`ClipnestApp/Sources/UI/Picker/HighlightedText.swift:19-40`) turns these
`Range<String.Index>`s into a styled `AttributedString` (accent-tinted
background) for `ItemRow`/`SnippetRow` — kept out of `ClipnestCore` since
`AttributedString` styling is a presentation concern.

**Edge cases handled**
- Empty search text → matches everything (both stores' query methods).
- `text` and `kind` both set → AND semantics, not OR.
- Very large `previewText` (100k+ chars) still matches a substring buried in the middle.
- `offset` at or beyond the total count → empty result, no crash.
- `limit` caps the result even when more items match.
- Snippet query never inspects `keyword`.

**Tests.** `Tests/ClipnestCoreTests/SearchHighlighterTests.swift` — empty
query, no match, single match, case-insensitivity, multiple non-overlapping
matches. `ClipStoreTests.swift`/`SwiftDataClipStoreTests.swift` — the
`query ...` cases from `:362` onward (text-only, kind-only, AND-combination,
scope, offset/limit, huge-previewText substring). `SnippetStoreTests.swift`/
`SwiftDataSnippetStoreTests.swift` — `query matches by title (Tag),
case-insensitive` (`:114`), `query matches by body, case-insensitive`
(`:126`), `query title (Tag) and body combine with OR, not AND` (`:138`),
`query never checks keyword` (`:151`).

**Gotchas / constraints**
- `fetchAll(matching:)` is unbounded — never call it from anything
  user-facing; it exists only for legacy source compatibility.
- Search matching is substring, not fuzzy/token-based — no ranking beyond
  scope's fixed sort order.

---

## 7. The picker UI

**What it does.** A non-activating floating panel (⌥⌘V, or the menu bar's
"Open Clipnest") with live search over History/Pinned/Snippets, keyboard
navigation, hover previews, and select-to-paste — without ever stealing
keyboard focus from whatever app the user was in.

**Key files**
- `ClipnestApp/Sources/UI/Picker/PickerPanel.swift:27-207` — window chrome
- `ClipnestApp/Sources/UI/Picker/PickerView.swift:87-500` — SwiftUI content + key handling
- `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift:166-1218` — state/data flow
- `ClipnestApp/Sources/UI/Picker/PagedQuery.swift:49-231` — shared paged-query engine (paging/generation/task lifecycle) behind both the Rows and Snippets pipelines (review #6 DRY follow-up)
- `ClipnestApp/Sources/UI/Picker/ItemRow.swift`, `SnippetRow.swift` — row rendering
- `ClipnestApp/Sources/UI/Picker/TabSwitcher.swift`, `TypeFilterChips.swift` — tab/kind filtering UI
- `ClipnestApp/Sources/UI/Picker/ItemPreview.swift`, `ItemPreviewController.swift`, `ItemThumbnailCache.swift` — hover preview
- `ClipnestApp/Sources/UI/Picker/HighlightedText.swift`, `WindowPlacement.swift`

**How it works — the panel (`PickerPanel`).**
An `NSPanel` subclass configured `styleMask: [.borderless,
.nonactivatingPanel]` (`PickerPanel.swift:83-91`) — the same technique
Spotlight-style launchers use: a `.nonactivatingPanel` can become key (to
accept keyboard input in the search field) **without** activating its owning
app, so `NSWorkspace.frontmostApplication` keeps reporting whichever app the
user was in before opening the picker (essential for [§8](#8-paste--insertion)'s
paste targeting). `show(at:)` (`:170-175`) therefore calls
`orderFrontRegardless()` + `makeKey()`, deliberately never `NSApp.activate`
or `makeKeyAndOrderFront`. `level = .popUpMenu` + `collectionBehavior =
[.canJoinAllSpaces, .fullScreenAuxiliary]` (`:113-132`) let it draw over
another app's full-screen Space — `.floating` alone sat too low. A local
`NSEvent` monitor installed in `configure()` (`:148-156`) intercepts ⌘⌫
*ahead of* the search field's field editor (which would otherwise consume it
as "delete to line start" before SwiftUI's `.onKeyPress` ever saw it) and
calls `onCommandDelete`. Position clamping is shared with
`SnippetEditorWindow` via `WindowPlacement.clampedOrigin`
(`WindowPlacement.swift:33-40`).

**How it works — data flow (`PickerViewModel`).**
`PickerViewModel` is `@MainActor final class ... ObservableObject`
(`PickerViewModel.swift:165`). As of the T50/T51 "DB-virtualization" design
(the file's own top doc comment, `:18-136`), it does **not** hold the entire
history in memory: it holds only the current *window* —
`rows: [ClipItem]` (History/Pinned share one window since only one tab is
visible at a time, `:235`) and `snippetRows: [Snippet]` (`:242`) — fetched
via `ClipStore.query(...)`/`SnippetStore.query(...)` (real, filtered/sorted/
paginated store calls, [§6](#6-search)). Since the review #6 DRY follow-up,
the paging bookkeeping (`PageState`, `PagedQuery.swift:53-56`) and the
generation-counter race guard live in a shared `PagedQuery<Element>` engine
rather than duplicated per pipeline — `rowsQuery`/`snippetsQuery`
(`PickerViewModel.swift:365-366`) are its two instances, one per element
type; `rows`/`snippetRows` themselves stay directly on `PickerViewModel`
since only a `@Published` stored property on the view model can drive
SwiftUI's bindings. Infinite-scroll paging is driven by `loadMoreIfNeeded()`
(`:724-731`, called by `PickerView` when the last loaded row appears).

Search input is decoupled from the query pipeline for responsiveness:
`PickerView` binds the search field to a **local** `@State searchText`
(`PickerView.swift:94`, zero async in the typing path) and reports every
change to `searchTextChanged(_:)` (`PickerViewModel.swift:500-504`), which
records it in `currentSearchText` and kicks off `runActiveTabQuery(policy
:debounced:)` (`:528-538`) with a `Self.searchDebounce = 400ms`
(`:180`) debounce. Tab switches (`activeTab`'s `didSet`, `:217-229`) and
kind-filter chip changes (`query`'s `didSet`, `:193-210`) requery
immediately, no debounce. A **generation counter** guarantees
latest-request-wins whenever multiple async triggers race — only the
result whose generation is still current when its `await` returns is ever
applied. Since the review #6 DRY follow-up this counter is no longer a pair
of `PickerViewModel` properties: it's `PagedQuery.generation`, bumped
internally by each pipeline's own `beginNewGeneration()`
(`PagedQuery.swift:73, 111-117`) every time that pipeline's `rowsQuery`/
`snippetsQuery` instance (re)populates its item array.

Commit actions (Return, ⌘P, ⌘S, ⌘⌫) must never act on a stale row left over
from before a still-pending debounced requery resolves: each one
(`selectHighlighted()`, `togglePinHighlighted()`, `saveHighlightedAsSnippet()`,
`deleteHighlighted()`) starts an internal `Task` that first awaits
`flushActiveTabPendingQuery()` (`:997-1004`), which cancels whatever's
pending and runs an immediate (non-debounced) query against the *live*
`currentSearchText` before reading `highlightedItem`/`highlightedSnippet`.

Selection after a query lands follows one of three `SelectionPolicy` cases
(`:374-389`, resolved generically by `resolvedSelection(_:currentID:result:)`
at `:815-834`): `.hardReset` (search/tab/kind change — select the new first
result), `.softReconcile` (live capture, post-mutation refresh — keep the
current selection if still present, else fall back to first), `.selectNear
(previousIndex:)` (post-delete — select whatever now sits at the deleted
row's old index, so deleting doesn't yank the highlight to the top).

**How it works — tabs & filtering.** `PickerTab` (`TabSwitcher.swift:16-30`)
is `.history`/`.pinned`/`.snippets`, `Int`-backed so ⌘1/⌘2/⌘3
(`PickerView.swift:187-195`) map directly to `rawValue + 1`. `TabSwitcher`
(`:36-60`) is a plain segmented control bound to `viewModel.activeTab`.
`TypeFilterChips` (`TypeFilterChips.swift:41-82`) offers exactly `[nil
(All), .text, .image, .file, .link]` — `.richText` is reachable only via
"All" — bound directly to `SearchQuery.kindFilter`; removed entirely (not
merely hidden) on the Snippets tab since kind filtering has no meaning there
(`PickerView.swift:214-216`).

**How it works — rows & previews.** `ItemRow` (`ItemRow.swift:80-184`)
renders a kind-specific leading icon/thumbnail (`ItemIconThumbnail`,
`:193-260`, async-loads `.image` bytes via `BlobStore` or a generic
`NSWorkspace` type-icon for `.file` — **never** `icon(forFile:)`, which
triggers TCC + QuickLook generation for protected folders and was the
original cause of a multi-second freeze), highlighted `previewText`
(`HighlightedText`), a relative timestamp, and three always-visible trailing
actions (pin/unpin, save-as-snippet, delete) plus a matching right-click
context menu. `SnippetRow` (`SnippetRow.swift:34-84`) mirrors this shape for
snippets (edit/delete instead of pin/save/delete). `ItemThumbnailCache`
(`ItemThumbnailCache.swift:18-32`) is a shared `NSCache`-backed, in-memory
thumbnail cache keyed by content-addressed `blobPath`/`fileReference` — a
cache hit is always correct since a given key's bytes never change.

Hover-driven preview: `ItemRow`/`SnippetRow`'s `onHover` reports to
`PickerViewModel.hoverItem(_:)` (`:740-743`), which — after a short
show-delay or close-grace (`previewShowDelay`/`previewCloseGrace`, `:355,
:359`) — resolves via `resolvePreview()`
(`:772-797`) to a `previewTargetID`. `PickerView` watches that via
`.onChange` (`PickerView.swift:112-125`), resolves the actual `ClipItem`
(or, on the Snippets tab, synthesizes one from the snippet's body,
`:117-120`), and forwards it to `viewModel.updatePreview`, a closure
`AppEnvironment` wires to the real `ItemPreviewController.update(...)`
(`AppEnvironment.swift:171-178`). `ItemPreviewController`
(`ItemPreviewController.swift:21-139`) presents `ItemPreview` in its own
borderless, `.nonactivatingPanel`-style-masked child `NSPanel` — same
never-`makeKey()` technique as `PickerPanel` itself, so hovering a row can
never steal the search field's first-responder status. `ItemPreview.swift`
renders per-kind: images scaled to a definite size (`ScaledImage`,
`:81-101`, needed because `NSHostingController.fittingSize` collapses a
plain resizable image to near-zero), text loaded in `2_000`-character chunks
as the popover scrolls (`TextPreview`, `:110-171`), and file metadata
(name/size/path) read off-main-thread with **no** file-system access at
capture time (`FilePreview`, `:179-223`).

**How it works — keyboard.** `PickerView.handle(_:)`
(`PickerView.swift:154-199`) is the single `.onKeyPress` handler for
Esc (dismiss), Return / ⌥-Return (paste rich / paste plain), ↑/↓ (move
selection), Delete (delete highlighted), ⌘F (focus search), ⌘P (toggle pin),
⌘S (save as snippet), ⌘N (new snippet, Snippets tab only), ⌘1/⌘2/⌘3 (switch
tabs). Return is handled both here *and* via the search field's own
`.onSubmit` (`:231`) — belt-and-suspenders, since which of the two actually
receives a given Return keystroke isn't reliably verifiable headlessly;
both call `selectHighlighted()`, so there's no double-paste risk.

**Edge cases handled**
- Typing while a previous debounced search is still pending → generation counter discards the stale result.
- Commit action (paste/pin/delete) fired right after typing → flushed against the live search text first, never a stale row.
- Deleting the selected row → selection follows the row that now occupies its old index rather than jumping to the top.
- A live capture landing while the picker is open → only requeries if visible **and** History is active (Pinned/Snippets can't contain a fresh, always-unpinned item).
- Empty result sets → dedicated empty-state views per tab, distinguishing "no history yet" from "no matches for <query>".

**Tests.** None — `ClipnestApp` (the App/UI target) has no automated test
target; see [Testing strategy](#testing-strategy).

**Gotchas / constraints**
- `PickerViewModel` deliberately never eagerly loads all history — always
  extend it via `query(...)`'s offset/limit windowing, never by reverting to
  `fetchAll`.
- Any new UI surface shown *while the picker is open* (like
  `ItemPreviewController`) must follow the same never-`makeKey()` /
  `orderFrontRegardless()` pattern, or it will steal focus from the search
  field.

---

## 8. Paste / insertion

**What it does.** Selecting a row writes its content to the system
pasteboard and, only when Accessibility is granted, also synthesizes ⌘V into
whatever app was frontmost before the picker opened — falling back silently
to "it's on the clipboard" otherwise.

**Key files**
- `Sources/ClipnestCore/Paste/Paster.swift:136-210`
- `Sources/ClipnestCore/Paste/FrontmostAppTracker.swift:55-79`
- `Sources/ClipnestCore/Paste/EventSynthesizing.swift:12-17`
- `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift:875-978` (`select`/`pasteContent`/`pasteAndDismiss`)

**How it works.**
`FrontmostAppTracker.record()` (`FrontmostAppTracker.swift:68-70`) is called
by `AppEnvironment.showPicker()` (`AppEnvironment.swift:278-281`) —
the single choke point both the global hotkey and the menu bar's "Open
Clipnest" already share — *immediately before* the panel is shown, so the
paste target is captured before the picker (a non-activating panel, but
focus can still shift transiently) is even visible. `consume()`
(`FrontmostAppTracker.swift:75-78`) returns and clears the most recently
recorded `FrontmostAppRef` (bundle ID + pid) — last-recorded wins, and a
stale target from a previous session is never reused.

`PickerViewModel.pasteContent(for:plainText:)`
(`PickerViewModel.swift:892-940`) maps a `ClipItem` to a `PasteContent`
based on `kind` and the `plainText` flag (⌥-Return = "paste without
formatting"):
- `.text`/`.link` → `.text(previewText)` always (both store their *full*
  content there).
- `.richText` → reads its RTF blob via `blobStore.read(blobPath:)` and
  returns `.richText(rtf:plain:)`; a legacy `.richText` item captured
  before RTF was stored (no `blobPath`) falls back to plain `previewText`
  rather than no-op-ing.
- `.image` → reads bytes via `BlobStore`; a missing/corrupt blob logs
  (metadata only) and returns `nil` (silent no-op — no safe content to
  paste).
- `.file` → re-offers the original file via `fileReference` as `.file(url)`.
- Any text-bearing kind, when `plainText == true`, strips down to `.text
  (previewText)` regardless of its richer stored form.

`pasteAndDismiss(_:)` (`:960-978`) is the shared tail for both `select(_:)`
and `pasteSnippet(_:)`: it calls `frontmostAppTracker.consume()`, then
**`dismiss()` first**, *then* starts a `Task` that calls `paster.paste
(content, targetingFrontmostApp:)`. Dismiss-before-paste is deliberate, not
incidental: `Paster`'s `CGEventSynthesizer` posts through the *global* HID
event tap after a short delay, and if Clipnest's panel still held key focus
when that posts, the OS could deliver the synthetic keystroke to Clipnest's
own search field instead of the target app.

`Paster.paste(_:targetingFrontmostApp:)`
(`Paster.swift:179-209`) always writes the pasteboard synchronously first
(`:183-202`, one case per `PasteContent` — `.image` normalizes both possible
captured formats, PNG or TIFF, into `.tiff` via `NSImage(data:)
.tiffRepresentation` before writing, since that's what virtually every macOS
app expects). Then: if `isAccessibilityGranted()` is `false`, or no
`frontmostApp` was provided, it stops there — no error, no crash, the
documented clipboard-only fallback (`:204`). Otherwise it waits
`synthesisDelay` (`Paster.defaultSynthesisDelay = 40ms`, `:147`) — giving the
OS time to hand focus back to the target app after `dismiss()` — then calls
`eventSynthesizer.synthesizeCommandV(targeting:)`.

`CGEventSynthesizer` (`Paster.swift:91-126`) is the real implementation:
posts a ⌘V key-down/key-up pair through the **global** HID event tap
(`CGEvent.post(tap: .cghidEventTap)`), not pid-targeted `postToPid` — pid
targeting proved unreliable for delivering a synthetic keystroke to a
previously-frontmost app in practice.

Right after `paster.paste` returns (success or thrown `PasteError`), the
same `Task` calls `self.suppressOwnPasteboardWrite(self.pasteboard
.changeCount)` (`:973-976`) — wired by `AppEnvironment` to
`ClipboardMonitor.ignore(changeCount:)` (`AppEnvironment.swift:222-224`) —
so the picker's own write is never recaptured as new history (see
[§1](#1-clipboard-capture)).

**Decision tree (summarized).**
```
select(item) → pasteContent(for:) → write pasteboard (always)
    ├─ Accessibility NOT granted            → stop (clipboard-only; no error)
    ├─ Accessibility granted, no target app → stop (clipboard-only; no error)
    └─ Accessibility granted + target app   → wait 40ms → synthesize ⌘V
```
There is no "beep" in the `Paster` path — a beep only happens in the
*snippet-expansion* flow (see [§9](#9-snippets)) when nothing can be replaced at all.

**Edge cases handled**
- No Accessibility grant → silent clipboard-only fallback, never a crash or blocking prompt from the *paste* path itself (see [§11](#11-permissions) for the prompting behavior).
- `.image`/`.file` with a missing/corrupt blob → logged, `select` no-ops rather than pasting garbage.
- Undecodable image bytes at paste time → `Paster` throws `PasteError.invalidImageData` *before* writing anything to the pasteboard.
- A genuine `PasteError` thrown by the synthesizer → caught, logged (metadata only), non-fatal — the pasteboard write already succeeded.

**Tests.** `Tests/ClipnestCoreTests/PasterTests.swift` — writes-then-
synthesizes-when-granted, stays-clipboard-only-when-not-granted /
no-target, propagates a genuine `PasteError`, rich-text writes both RTF and
plain representations (`:214`). `Tests/ClipnestCoreTests/
FrontmostAppTrackerTests.swift` — record/consume, last-recorded-wins,
consume-clears. `PickerViewModel`'s decision logic
(`pasteContent(for:plainText:)`) has no dedicated App-target test — see
[Testing strategy](#testing-strategy).

**Gotchas / constraints**
- `Paster` never touches `BlobStore` itself — callers (`PickerViewModel`)
  must load bytes before calling `paste(_:targetingFrontmostApp:)`.
- The 40ms `synthesisDelay` exists specifically because the event tap is
  global, not pid-targeted — don't remove it without re-verifying paste
  reliability against a real frontmost-app handoff.

---

## 9. Snippets

**What it does.** User-authored, reusable text blocks with an optional
keyword; pasteable from the Snippets tab, or expandable in *any* app by
typing the keyword, selecting it, and pressing ⌥⌘E.

**Key files**
- `Sources/ClipnestCore/Model/Snippet.swift:8-28`
- `Sources/ClipnestCore/Store/SnippetStore.swift:16-45`, `SwiftDataSnippetStore.swift`
- `Sources/ClipnestCore/Paste/SnippetExpander.swift:28-89`
- `Sources/ClipnestCore/Paste/SelectedTextAccessing.swift:7-16`, `SelectionReplacing.swift:38-45`
- `ClipnestApp/Sources/System/SelectedTextAccessing.swift:20-52` (AX implementation)
- `ClipnestApp/Sources/System/ClipboardSelectionReplacer.swift:22-134` (clipboard-fallback implementation)
- `ClipnestApp/Sources/UI/Picker/SnippetFormView.swift`, `SnippetEditorWindow.swift`, `SnippetRow.swift`

**How it works — model & CRUD.** `Snippet` (`Snippet.swift:8-28`) is
`{ id, title, body, keyword: String?, createdAt }`. CRUD goes through
`SnippetStore` ([§5](#5-persistence)/[§6](#6-search) cover persistence/query in detail).
`findByKeyword(_:)` (`SnippetStore.swift:40-44`,
`SwiftDataSnippetStore.swift:195-215`) returns the **newest** snippet whose
`keyword`, trimmed and case-folded, equals the (similarly normalized) needle
— snippets with a `nil`/blank keyword never match. In the SwiftData
implementation this fetches only keyworded rows (a `#Predicate` on `keyword
!= nil`) and does the trim/case-fold match in Swift, since that
transformation on an optional field isn't expressible in a `#Predicate` —
snippet counts are small (user-authored), so this is cheap.

**How it works — the editor UI.** The picker's create/edit form shows
exactly **two** fields: **Tag** (maps to `Snippet.title`) and **Body**
(`SnippetFormView.swift:44-135`). Saving passes the trimmed Tag as **both**
`title` and `keyword` (`:123-134`) — the Tag doubles as the expansion
keyword; there's no separate keyword field. `SnippetFormMode`
(`:31-42`) is `.create` (empty), `.createFromClip(String)` ("Save as
Snippet" from a History/Pinned row, prefills Body only —
`PickerViewModel.presentSaveAsSnippetForm(from:)`, `PickerViewModel.swift
:1101-1104`, gated to `.text`/`.link` items only), or `.edit(Snippet)`
(prefills both fields). The form is hosted in `SnippetEditorWindow`
(`SnippetEditorWindow.swift:37-163`) — a real, titled, activating
`NSWindow`, **not** a `.sheet()` on `PickerPanel`: a sheet attached to a
`.nonactivatingPanel` inherits its inability to ever truly gain key status,
so its fields could never receive typed input. It's positioned as a
side-by-side pair with the picker via `WindowPlacement.pairLayout`
(`WindowPlacement.swift:70-107`), which may shift the *picker's* frame
(never resize it) so the two windows never overlap when they can both fit
the screen.

**How it works — keyword expansion (⌥⌘E), the two-strategy design.**
`SnippetExpander.expand()` (`SnippetExpander.swift:62-88`) is
`@MainActor` (it drives Accessibility, the pasteboard, key synthesis, and
`NSSound.beep()`):
1. **Accessibility first**: `selectedText.readSelectedText()`
   (`SelectedTextAccessing.swift:7-10`, AX-backed via `AXSelectedTextAccessor`
   in the app target, `ClipnestApp/Sources/System/SelectedTextAccessing.swift:20-52`,
   using `kAXSelectedTextAttribute`). If there's a non-blank selection,
   look it up via `snippetStore.findByKeyword`. A read-but-no-match beeps
   and **stops** — it does not fall back to the clipboard, since a
   successful AX read means the keyword is real and a clipboard re-read
   would yield the same non-match. If it matches, `selectedText
   .replaceSelectedText(with:)` writes the body directly via AX, with
   **no pasteboard involvement at all** — this is the fast, non-disruptive
   path, and works for native/most Cocoa text (TextEdit, Notes, Safari
   fields).
2. **Clipboard fallback** (only reached when AX can't read the selection at
   all — Electron/Chrome/Java apps don't expose it to AX — or read it but
   the AX *write* was refused): `ClipboardSelectionReplacer
   .replaceSelection(bodyForSelection:)`
   (`ClipboardSelectionReplacer.swift:50-84`) is the universal, works-in-any-
   app path. It runs the entire transaction atomically from the clipboard's
   point of view: `beginSuppression()` (→ `ClipboardMonitor.pause()`),
   snapshot every pasteboard item/type verbatim (`snapshotClipboard()`,
   `:116-126`), wait `modifierClearDelay` (60ms, so the user's still-held
   ⌥⌘ doesn't merge with the synthetic keystroke), post a synthetic ⌘C and
   poll (`waitForChange`, `:88-96`, up to `copyMaxWait = 500ms`) for the
   pasteboard to actually change, read the resulting selection, look it up,
   write the matched body and post a synthetic ⌘V, wait `pasteSettle`
   (120ms) for it to land, then — via `defer` — restore the original
   clipboard snapshot and `endSuppression()` (→ `ignore(changeCount:)` +
   `resume()`). The clipboard ends up byte-for-byte as it started; capture
   suppression means the transient copy/paste never lands in history.
3. If neither strategy replaces anything, `expand()` calls `beep()`
   (default `NSSound.beep()`).

**Edge cases handled**
- AX read succeeds, no keyword match → beep, no clipboard fallback attempted.
- AX read succeeds and matches, but the AX *write* is refused → falls through to the clipboard path instead of silently failing.
- AX can't read at all (Electron/etc.) → clipboard fallback runs; if that also finds nothing selected → beep.
- Multiple snippets share the same keyword → the newest (`createdAt`) wins.
- Keyword lookup is trimmed + case-folded on both sides (stored keyword and typed selection).
- The clipboard-fallback transaction always restores the original clipboard, even on failure (via `defer`).

**Tests.** `Tests/ClipnestCoreTests/SnippetExpanderTests.swift` — one test
per branch of the decision tree: `AX can read + match: replaces via AX,
never uses the clipboard, never beeps` (`:57`), `AX reads but no match:
beeps, does NOT fall back to the clipboard` (`:74`), `AX can't read
(Electron): falls back to the clipboard, which matches + replaces` (`:91`),
`AX can't read and the clipboard reads nothing: beeps` (`:109`), `AX reads +
matches but the AX WRITE is refused: falls back to the clipboard` (`:126`).
`Tests/ClipnestCoreTests/SnippetStoreTests.swift`/
`SwiftDataSnippetStoreTests.swift` — `findByKeyword` matching/trimming/
newest-wins (`:211`/`swiftDataFindByKeyword`). `ClipboardSelectionReplacer`
(the real AppKit implementation) has no automated test — see
[Testing strategy](#testing-strategy).

**Gotchas / constraints**
- `Snippet.keyword` is set to the same value as `title` by the current UI —
  there's no way today to have a display Tag that differs from the
  expansion keyword.
- `SnippetExpander.expand()` is `@MainActor` and synchronous-looking but
  internally `async` — callers (the global hotkey handler) must `await` it
  inside a `Task`.

---

## 10. Global hotkey

**What it does.** ⌥⌘V opens the picker from anywhere; ⌥⌘E triggers snippet
expansion — both work without the menu bar, via a global event tap.

**Key files**
- `ClipnestApp/Sources/System/HotkeyManager.swift:13-67`

**How it works.** Built on the third-party `KeyboardShortcuts` package
(Sindre Sorhus, MIT — the one approved external dependency, `ClipnestApp`-
only) rather than a hand-rolled Carbon/`CGEventTap` implementation.
`KeyboardShortcuts.Name.togglePicker` (`:29-32`) defaults to **⌥⌘V**
(Option+Command+V) — a deliberate override of an earlier ⌘⇧V default,
applied automatically the first time the `Name` is referenced with nothing
already saved in `UserDefaults` (that's `KeyboardShortcuts.Name.init`'s own
documented behavior). `.expandSnippet` (`:37-40`) defaults to **⌥⌘E**.
`HotkeyManager.register(onToggle:)`/`registerExpandSnippet(onExpand:)`
(`:57-65`) are thin wrappers around `KeyboardShortcuts.onKeyDown(for:action:)`,
called exactly once from `AppEnvironment.registerHotkey()`
(`AppEnvironment.swift:262-268`), which wires `.togglePicker` to
`self.showPicker()` and `.expandSnippet` to `Task { await
self.snippetExpander.expand() }`.

**Edge cases handled** — none of substance live in this file:
`KeyboardShortcuts` itself owns the actual low-level global event tap,
persistence of any user-customized shortcut, and the first-launch-default
behavior; there's no meaningful pure logic here to unit test (mirrors
`PermissionsManager`'s identical rationale).

**Tests.** None — intentionally. Registration itself (does pressing ⌥⌘V
from another app actually open the picker) is only verifiable by an actual
run, not headlessly.

**Gotchas / constraints**
- `KeyboardShortcuts` is pinned to the 3.x line specifically because
  `Name`/`Shortcut` weren't `Sendable`/`nonisolated` in 1.x — don't downgrade
  without re-verifying Swift 6 strict-concurrency compatibility.
- The default shortcut only applies "the first time this `Name` is
  referenced with nothing already saved" — changing the `initial:` value in
  code has no effect for a user who's already launched a build with the old
  default.

---

## 11. Permissions

**What it does.** Wraps macOS's Accessibility trust check so the rest of
the app never calls the raw C API directly, and prompts for it only from an
actual paste attempt — never at launch, never just from opening the picker.

**Key files**
- `ClipnestApp/Sources/System/PermissionsManager.swift:42-89`

**How it works.** `PermissionsManager` is a non-`@MainActor` `enum`
(deliberately — both underlying calls are plain thread-safe C functions, and
keeping it non-isolated lets it be passed straight through as `Paster`'s
`@Sendable` `isAccessibilityGranted` closure with no actor hop):
- `isGranted` (`:49-51`) — silent `AXIsProcessTrusted()`. Never shows a
  system prompt; this is the check that must stay silent so opening the
  picker or selecting an item never blocks on an unsolicited dialog.
- `requestAccess()` (`:60-64`) — prompting `AXIsProcessTrustedWithOptions
  ([kAXTrustedCheckOptionPrompt: true])`, for an explicit user-initiated
  "Grant Accessibility" affordance.
- `isGrantedPromptingIfNeeded()` (`:86-88`) — `isGranted || requestAccess()`.
  This is what `AppEnvironment` actually feeds `Paster`'s
  `isAccessibilityGranted` (`AppEnvironment.swift:116-118`): if already
  granted, silent and identical to `isGranted`; if not granted, it prompts
  macOS's "grant access" dialog *right there*, so a paste that falls back to
  clipboard-only has an obvious, immediate explanation instead of silently
  degrading. It still returns `false` either way for *that* paste attempt —
  granting access requires the user to act in System Settings and never
  takes effect synchronously — only a *later* paste attempt gets the real
  synthesized ⌘V.

The file needs `@preconcurrency import ApplicationServices` (`:22`) because
`kAXTrustedCheckOptionPrompt` is an `extern CFStringRef` imported as a
global `var`, which Swift 6 strict concurrency otherwise flags as unaudited
shared mutable state even though it's effectively a read-only constant.

**What degrades without it.** Reading the pasteboard, capturing history, and
opening/searching the picker all work fully without Accessibility — nothing
in [§1](#1-clipboard-capture)–[§7](#7-the-picker-ui) requires it. Only two things need it: `Paster`'s
synthesized ⌘V step (falls back to clipboard-only — [§8](#8-paste--insertion)), and
`SnippetExpander`'s AX-read/replace path and the `ClipboardSelectionReplacer`
fallback's synthetic keystrokes (without it, AX reads return `nil` and the
synthetic ⌘C is dropped — the expander ends up beeping, [§9](#9-snippets)).

**Tests.** None — a direct two-call passthrough with no pure branching logic
of its own (matching `HotkeyManager`'s identical precedent). The branching
this feeds (`Paster.paste`'s granted/not-granted paths) is already covered
by `PasterTests.swift` with a mocked `isAccessibilityGranted` closure.

**Gotchas / constraints**
- Never call `requestAccess()`/`isGrantedPromptingIfNeeded()` from app
  launch or from simply opening the picker — only from an actual paste
  attempt. This is a stated privacy/UX invariant, not just a style
  preference.
- Accessibility grants are keyed to the binary's code signature — an
  ad-hoc/unsigned dev build needs re-granting after every rebuild.

---

## 12. App lifecycle & DI

**What it does.** Wires every `ClipnestCore` service and the picker UI into
one owned dependency graph at launch, with no globals/singletons.

**Key files**
- `ClipnestApp/Sources/App/AppDelegate.swift:17-44`
- `ClipnestApp/Sources/App/AppEnvironment.swift:54-282`
- `ClipnestApp/Sources/App/ClipnestApp.swift:14-38`

**How it works.** `ClipnestApp` (`ClipnestApp.swift:14-38`) is the
`@main` SwiftUI `App`, whose only always-visible UI is a `MenuBarExtra`
("Open Clipnest" / "Quit") — no Dock icon, no main window. It adapts
`AppDelegate` via `@NSApplicationDelegateAdaptor` (`:15`).
`AppDelegate.applicationDidFinishLaunching(_:)`
(`AppDelegate.swift:22-38`) first sets `NSApp.setActivationPolicy(.accessory)`
(belt-and-suspenders alongside `INFOPLIST_KEY_LSUIElement` in `project.yml`
— the app never shows a Dock icon or steals focus on launch), then
constructs the single `AppEnvironment` (`try AppEnvironment()`), and calls
`environment.startCapture()` + `environment.registerHotkey()`. If
`AppEnvironment.init()` throws — the only realistic cause is the on-disk
SwiftData container failing to come up, see [§5](#5-persistence)'s migration-crash
discussion — there's no safe partially-initialized fallback: the error is
logged (metadata only, `.fault` level) and the app terminates
(`:30-37`).

`AppEnvironment.init()` (`AppEnvironment.swift:76-248`) builds the entire
graph in dependency order:
1. One shared `BlobStore` (`:78`) — the file's own top doc comment
   (`:9-16`) calls out that `ClipStore` and `ClipboardMonitor` **must**
   share this *exact* instance, not each construct their own default —
   both types have their own default `BlobStore` parameter for standalone
   unit-test convenience, but relying on those defaults here would silently
   give each its own instance pointed at the same directory: correct today,
   but one refactor away from drifting apart.
2. `PrivacyFilter`, `PasteboardReader`, `SwiftDataClipStore` (`:79-87`,
   production `ModelContainer` via `makeProductionContainer()`),
   `SwiftDataSnippetStore` (`:88-90`).
3. `SnippetExpander`, wired with the app-side AX/clipboard-fallback
   implementations (`:99-103`) since `ClipnestCore` can't reference
   app-only types.
4. `ClipboardMonitor` (`:105-110`), sharing `clipStore`/`pasteboardReader`/
   `blobStore` from steps above.
5. `Paster`, fed `PermissionsManager.isGrantedPromptingIfNeeded` (`:116-118`,
   see [§11](#11-permissions)), and `FrontmostAppTracker` (`:120-121`).
6. `PickerViewModel` (`:123-129`), then `PickerPanel` hosting `PickerView
   (viewModel:)` (`:132-135`).
7. `SnippetEditorWindow` (`:137-138`) and `ItemPreviewController`
   (`:143-144`).
8. **Post-construction wiring**, done after every piece above exists to
   break construction-order cycles (e.g. the panel's own SwiftUI content
   needs a way to dismiss the panel that hosts it, but the panel doesn't
   exist yet while that content is being built): `viewModel.dismiss`,
   `panel.onWillShow`/`onDidHide`/`onCommandDelete`, `viewModel
   .updatePreview`, `viewModel.presentSnippetEditor` (creates vs. updates a
   snippet based on which mode the editor was opened in), `viewModel
   .suppressOwnPasteboardWrite` → `monitor.ignore(changeCount:)`, `monitor
   .onCapture` → `viewModel.handleNewCapture()`, and the
   `clipboardReplacer.beginSuppression`/`endSuppression` closures →
   `monitor.pause()`/`ignore(changeCount:)`+`resume()`.

`startCapture()` (`:253-255`) and `registerHotkey()` (`:262-268`) are called
exactly once each, from `AppDelegate`. `showPicker()`
(`:278-281`) is the one method both the menu bar's "Open Clipnest" and the
global hotkey funnel through — it calls `frontmostAppTracker.record()`
*then* `pickerPanel.show()`, in that order, so [§8](#8-paste--insertion)'s paste target is
always captured before the picker itself can shift focus.

**Edge cases handled**
- `AppEnvironment.init()` throwing → clean, logged termination rather than a half-initialized app.
- Both trigger paths for opening the picker (menu bar, hotkey) share one `showPicker()` — no risk of one path forgetting to record the frontmost app.

**Tests.** None — `AppDelegate`/`AppEnvironment`/`ClipnestApp` compose real
AppKit/SwiftUI lifecycle objects and have no automated test target; see
[Testing strategy](#testing-strategy).

**Gotchas / constraints**
- Never construct a second `BlobStore`/`ClipStore`/`ClipboardMonitor`
  instance anywhere else in the app — `AppEnvironment` is the single owned
  graph; everything else receives its dependencies by injection.
- The post-construction closure-wiring block exists specifically to break
  circular construction dependencies — if adding a new cross-referencing
  pair of objects, follow that same "construct both, then wire closures
  after" pattern rather than trying to inject one into the other's
  initializer.

---

## Testing strategy

`ClipnestCore` is designed around **protocol seams** so every I/O-touching
dependency — the pasteboard (`PasteboardReading`/`MonitoredPasteboard`,
`ClipboardMonitor.swift:7-37`), persistence (`ClipStore`/`SnippetStore`,
`ClipStore.swift:35-86`/`SnippetStore.swift:16-45`), pasteboard writes
(`PasteboardWriting`, `Paster.swift:37-59`), key-event synthesis
(`EventSynthesizing`, `EventSynthesizing.swift:12-17`), frontmost-app
lookup (`FrontmostApplicationProviding`/`FrontmostAppReferenceProviding`,
`ClipboardMonitor.swift:12-15`/`FrontmostAppTracker.swift:32-34`), and
Accessibility-based selection access (`SelectedTextAccessing`/
`SelectionReplacing`, `SelectedTextAccessing.swift:7-16`/
`SelectionReplacing.swift:38-45`) — can be exercised with a deterministic
fake instead of the real system API. Two canonical in-memory stores,
`InMemoryClipStore`/`InMemorySnippetStore`, are the concrete `ClipStore`/
`SnippetStore` used by every `ClipnestCoreTests` test that needs a store
(the production app uses `SwiftDataClipStore`/`SwiftDataSnippetStore`
instead, tested in their own parallel suites,
`SwiftDataClipStoreTests.swift`/`SwiftDataSnippetStoreTests.swift`, so both
the interface contract *and* the real SwiftData-backed implementation are
covered).

Hard testing rules the whole suite follows: no real `Timer`-driven waiting
(`ClipboardMonitor.checkNow()` is always driven directly and synchronously);
no real key events synthesized in CI (`Paster`/`SnippetExpander` tests
always inject a mock `EventSynthesizing`/`SelectedTextAccessing`/
`SelectionReplacing`); no test ever touches the real system pasteboard,
Accessibility permission, or `~/Library/Application Support/Clipnest` (every
`BlobStore`/`SwiftData…Store` test points at a throwaway temp directory or
in-memory-equivalent container).

`Tests/ClipnestCoreTests/` (17 files) covers every `ClipnestCore` type
documented above. `Tests/ClipnestCoreTests/TestSupport/ImageFixtures.swift`
provides shared test image bytes.

**The `ClipnestApp` (App/UI) target has no automated tests.** Everything in
[§7 (picker UI)](#7-the-picker-ui), [§10 (hotkey)](#10-global-hotkey),
[§11 (permissions)](#11-permissions), and [§12 (lifecycle/DI)](#12-app-lifecycle--di) — `PickerView`,
`PickerViewModel`'s SwiftUI-facing behavior, `PickerPanel`, `ItemRow`/
`SnippetRow`, `ItemPreviewController`, `SnippetEditorWindow`,
`HotkeyManager`, `PermissionsManager`, `AppDelegate`/`AppEnvironment` — is
verified only by manual runtime checks (see individual "Manual-only" notes
in `.claude/project-context.md`'s decision log, e.g. D13's flagged
end-to-end paste verification). `PickerViewModel`'s pure *decision* logic
that doesn't touch AppKit (e.g. `pasteContent(for:plainText:)`'s per-kind
mapping) is exercised indirectly by `ClipnestCoreTests` covering the
`ClipnestCore` types it calls into (`Paster`, `BlobStore`), but has no
dedicated App-target unit test of its own. When changing anything under
`ClipnestApp/Sources/`, treat a real `xcodebuild`/manual run as the
verification step, not `swift test` (which only builds/runs
`ClipnestCoreTests`).
