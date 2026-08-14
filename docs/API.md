# ClipnestCore — API reference

`ClipnestCore` is Clipnest's dependency-light Swift package: all capture,
privacy-filtering, storage, search, and paste logic, with zero SwiftUI/UI
dependency, fully covered by `swift test` (see the repo root `Package.swift`
and `.claude/coding-standards.md`'s module-layout section). `ClipnestApp`
(the menu-bar app) is a thin SwiftUI/AppKit shell built on top of this
package — everything on this page is the actual contract that shell code
holds, so if you're extending Clipnest, writing a new frontend, or just want
to understand what each piece of the app is responsible for, this is where
to look.

This is the API/usage-reference slice of the project's docs — see
[`README.md`](../README.md) for the getting-started/overview and
[`docs/superpowers/specs/`](superpowers/specs/)/[`docs/superpowers/plans/`](superpowers/plans/)
for the original requirements/design trail.

Every type below is `Sendable` (Swift 6 strict concurrency) unless noted
otherwise, and every throwing function uses typed `throws` with the module's
own `Error` enum — see [Error handling](#error-handling).

## Contents

- [Model](#model) — `ClipItem`, `Snippet`, `ItemKind`
- [Store](#store) — `ClipStore`, `SnippetStore`, `BlobStore`
- [Clipboard](#clipboard) — `PasteboardReader`, `PrivacyFilter`, `ClipboardMonitor`
- [Search](#search) — `SearchQuery`, `SearchHighlighter`
- [Paste](#paste) — `Paster`, `PasteContent`, `FrontmostAppTracker`
- [Error handling](#error-handling)
- [Working example — capture → search → paste, end to end](#working-example--capture--search--paste-end-to-end)

---

## Model

Plain `Sendable` value types — no SwiftData, no UI framework knowledge. The
concrete stores (below) map these to/from their own private persistence
representation; a model type never crosses that boundary itself.

### `ItemKind`

```swift
public enum ItemKind: String, Codable, CaseIterable, Sendable {
  case text, richText, link, image, file
}
```
The kind of content a `ClipItem` holds. `.image` and `.richText` items
store their bytes (image bytes, RTF bytes respectively) in `BlobStore`,
referenced via `ClipItem.blobPath`; `.text`/`.link`/`.file` are
metadata-only (no blob).

### `ClipItem`

```swift
public struct ClipItem: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var createdAt: Date
  public var kind: ItemKind
  public var previewText: String
  public var contentHash: String
  public var pinned: Bool
  public var pinnedAt: Date?
  public var sourceAppName: String?
  public var sourceBundleID: String?
  public var byteSize: Int
  public var blobPath: String?
  public var fileReference: String?
}
```
A single captured clipboard entry. Key fields to know before you build
against this type:

| Field | Notes |
| --- | --- |
| `previewText` | For `.text`/`.link`, this is the **full** captured content — it's what `Paster` re-pastes, not just a UI preview. It currently has no length cap, so don't assume it's short (a copied source file or log can land here at full size). For `.richText`, it's the full plain-text extraction (no RTF formatting) — the formatted bytes live in the blob referenced by `blobPath` below, which is what actually gets pasted rich. For `.file`, it's just the filename. |
| `contentHash` | SHA-256 hex (`BlobStore.contentHash(of:)`) of the captured bytes — the dedup key `ClipStore.insertOrBumpDuplicate(_:)` matches on. |
| `blobPath` | Set for `.image` items (image bytes) and `.richText` items (RTF bytes); pass to `BlobStore.read(blobPath:)` to get the actual bytes. `nil` for `.text`/`.link`/`.file`. |
| `fileReference` | Set only for `.file` items — a file URL string re-offering the original file for paste. |
| `pinnedAt` | `nil` whenever `pinned == false`; set by `ClipStore.setPinned(_:pinned:)`, never assigned directly by capture. |

### `Snippet`

```swift
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var body: String
  public var keyword: String?
  public var createdAt: Date

  public init(id: UUID = UUID(), title: String, body: String, keyword: String? = nil, createdAt: Date = Date())
}
```
A user-authored, reusable snippet (as opposed to captured clipboard
history). `title` is the picker's single "Tag" field (`SnippetFormView`) —
the Tag is saved as BOTH `title` (the label shown in the Snippets list) and
`keyword` (the same value): typing the Tag in any app, selecting it, and
pressing ⌥⌘E replaces it with `body`, via `SnippetExpander` calling
`SnippetStore.findByKeyword(_:)`. There is no separate keyword-entry field —
the Tag doubles as both.

---

## Store

### `ClipStore` (protocol)

```swift
public protocol ClipStore: Sendable {
  func insertOrBumpDuplicate(_ item: ClipItem) async throws -> ClipItem
  func fetchAll(matching query: SearchQuery?) async throws -> [ClipItem]
  func fetchPinned() async throws -> [ClipItem]
  func query(
    text: String, kind: ItemKind?, scope: ClipScope, offset: Int, limit: Int
  ) async throws -> [ClipItem]
  func setPinned(_ id: UUID, pinned: Bool) async throws          // throws .notFound
  func delete(_ id: UUID) async throws                            // throws .notFound
  func clearHistory() async throws
  func enforceRetention(cap: RetentionCap?) async throws
}
```
CRUD + dedup + query access to captured history. Two implementations ship
today: `SwiftDataClipStore` (production — private `@Model` entity behind
this protocol, never exposed) and `InMemoryClipStore` (the canonical store
for `ClipnestCoreTests`, and usable directly if you just need an ephemeral
store). Both are constructed with a `BlobStore` they share with the rest of
the app, since deleting an item also deletes its blob (see
`deleteBlobs(for:using:)`, shared internally between both implementations).

- **`insertOrBumpDuplicate(_:)`** — the dedup entry point. If an item with
  the same `contentHash` already exists, its `createdAt` is bumped to
  `item`'s instead of inserting a second row; otherwise `item` is inserted
  as-is. Always returns the item as actually stored.
- **`query(text:kind:scope:offset:limit:)`** — the real, production
  filter/paging path the picker actually calls (search box + kind chips +
  History/Pinned tab). The store does ALL filtering, sorting, and paging:
  `scope` selects `.history` (`pinned == false`, `createdAt` descending) or
  `.pinned` (`pinned == true`, `pinnedAt` ascending); `text` is a
  case-insensitive substring match against `previewText` (empty text
  matches everything); `kind` is an exact match when non-nil (`nil` matches
  every kind); `text` and `kind` combine with AND. `offset`/`limit` window
  the already-filtered-and-sorted result — both must be `>= 0`.
- **`fetchAll(matching:)`** — every item, newest-first, unbounded and
  unfiltered. `query` (the `SearchQuery` parameter — not to be confused
  with the `query(text:kind:scope:offset:limit:)` method above) is accepted
  for source compatibility but always **ignored**; the picker no longer
  calls this method — use `query(text:kind:scope:offset:limit:)` for
  anything user-facing. Pass `nil`.
- **`fetchPinned()`** — pinned items only, newest-first by `createdAt`
  (superseded for picker use by `query(scope: .pinned, ...)`, which sorts
  by `pinnedAt` instead — kept for callers that just want the full pinned
  set with no paging).
- **`enforceRetention(cap:)`** — deletes unpinned items beyond `cap`
  (`RetentionCap.maxCount(_:)` or `.maxAge(_:)`), oldest first; `cap == nil`
  deletes nothing. Pinned items are **never** affected by any cap, no
  matter how it's configured.

```swift
public enum RetentionCap: Equatable, Sendable {
  case maxCount(Int)
  case maxAge(TimeInterval)   // seconds
}

/// Which slice of clipboard history `ClipStore.query(...)` should return.
public enum ClipScope: Sendable, Equatable {
  case history   // unpinned, createdAt descending (newest first)
  case pinned    // pinned, pinnedAt ascending (earliest-pinned first)
}

public enum ClipStoreError: Error, Equatable, Sendable {
  case notFound
  case ioFailure(underlying: String)
}
```

### `SnippetStore` (protocol)

```swift
public protocol SnippetStore: Sendable {
  func create(_ snippet: Snippet) async throws -> Snippet
  func update(_ id: UUID, title: String, body: String, keyword: String?) async throws -> Snippet  // throws .notFound
  func delete(_ id: UUID) async throws                                                             // throws .notFound
  func fetchAll() async throws -> [Snippet]
  func query(text: String, offset: Int, limit: Int) async throws -> [Snippet]
  func findByKeyword(_ keyword: String) async throws -> Snippet?
}
```
CRUD + query for user-authored snippets — the same `SwiftDataSnippetStore`/
`InMemorySnippetStore` split as `ClipStore`. `SnippetStoreError` mirrors
`ClipStoreError` (`.notFound` / `.ioFailure(underlying:)`).

- **`query(text:offset:limit:)`** — the paged path the Snippets tab
  actually calls: `text` matches case-insensitively against `title` OR
  `body` (either is enough — OR, not AND); empty `text` matches everything;
  `offset`/`limit` window the result (both must be `>= 0`).
- **`findByKeyword(_:)`** — returns the newest snippet whose `keyword`,
  whitespace-trimmed and case-folded, equals `keyword` similarly
  normalized; `nil` if `keyword` is blank once trimmed or nothing matches.
  Snippets with a `nil`/blank `keyword` never match. Powers the global
  snippet-expansion hotkey (⌥⌘E) via `SnippetExpander`.

### `BlobStore`

```swift
public struct BlobStore: Sendable {
  public init(baseDirectory: URL, fileManager: FileManager = .default)
  public static func defaultBaseDirectory(fileManager: FileManager = .default) -> URL
  public static func contentHash(of data: Data) -> String   // SHA-256 hex

  public func write(_ data: Data) throws -> String   // returns the relative blobPath
  public func read(blobPath: String) throws -> Data  // throws .notFound
  public func delete(blobPath: String) throws        // idempotent — missing blob is not an error
}
```
Content-addressed disk storage for payloads too large for `ClipItem`'s
metadata-only shape (currently `.image` and `.richText` bytes). Writing identical
bytes twice is a cheap no-op — the SHA-256 hash always maps to the same
path, so a second `write(_:)` just returns the existing `blobPath` without
touching disk again. **Always inject `baseDirectory` explicitly** — tests
must point it at a throwaway temp directory; production code uses
`defaultBaseDirectory()` (`~/Library/Application Support/Clipnest`).
`BlobStoreError` is `.notFound` (read-only; `delete` never throws this) or
`.ioFailure(underlying:)`.

---

## Clipboard

### `PasteboardReader`

```swift
public struct PasteboardReader: Sendable {
  public init()
  public func read(from pasteboard: PasteboardReading) -> Classification?
}
```
Classifies the *current* contents of a pasteboard into an `ItemKind` +
preview text + content hash + byte size, checking types in priority order
(`.fileURL` → image `.tiff`/`.png` → `.rtf` → `.string`, most-specific
first — a Finder file copy often also carries a text/image representation,
so a generic type must never win over a more specific one). Pure/I/O-free:
it never writes to `BlobStore` itself — `Classification.rawData` (populated
only for `.image` and `.richText`, the two kinds whose bytes must be
persisted) is the caller's job to persist (`ClipboardMonitor` does this,
off the main actor via `Task.detached`). `Classification.fileURL` is
populated only for `.file`. Returns `nil` if the pasteboard holds nothing
this reader understands. `PasteboardReading` is the injectable protocol
(`NSPasteboard` conforms) used so this is testable without a real
pasteboard.

### `PrivacyFilter`

```swift
public struct PrivacyFilter: Sendable {
  public static let builtInExcludedBundleIDs: Set<String>       // 1Password, Bitwarden, LastPass, Dashlane, Keeper
  public static let concealedPasteboardType: NSPasteboard.PasteboardType   // org.nspasteboard.ConcealedType
  public static let transientPasteboardType: NSPasteboard.PasteboardType  // org.nspasteboard.TransientType

  public init()
  public func shouldCapture(
    availableTypes: [NSPasteboard.PasteboardType],
    sourceBundleID: String?,
    isPaused: Bool,
    customExcludedBundleIDs: Set<String> = []
  ) -> Bool
}
```
The privacy gate every capture goes through. The concealed/transient marker
check and the paused flag are **unconditional** — no combination of the
other parameters can bypass them; `customExcludedBundleIDs` can only ever
*add* exclusions on top of the built-in password-manager list, never remove
anything. See `.claude/coding-standards.md`'s "Privacy / security musts" —
this is the one place that contract is enforced in code.

### `ClipboardMonitor`

```swift
@MainActor
public final class ClipboardMonitor {
  public static let defaultPollInterval: TimeInterval  // 0.4s

  public init(
    store: any ClipStore,
    privacyFilter: PrivacyFilter = PrivacyFilter(),
    reader: PasteboardReader = PasteboardReader(),
    blobStore: BlobStore = BlobStore(baseDirectory: BlobStore.defaultBaseDirectory()),
    pasteboard: any MonitoredPasteboard = NSPasteboard.general,
    frontmostApplicationProvider: any FrontmostApplicationProviding = WorkspaceFrontmostApplicationProvider(),
    pollInterval: TimeInterval = ClipboardMonitor.defaultPollInterval,
    excludedBundleIDsProvider: @escaping @Sendable () -> Set<String> = { [] },
    captureFailureHandler: @escaping CaptureFailureHandler = ClipboardMonitor.logCaptureFailure
  )

  public func start()          // begins polling on a repeating Timer
  public func stop()           // safe even if not started
  public func pause()          // isPaused = true — checkNow() still no-ops, doesn't crash/queue
  public func resume()
  public var isPaused: Bool { get }
  public func ignore(changeCount: Int)   // suppress recapturing Clipnest's own pasteboard write
  @discardableResult public func checkNow() async -> ClipItem?    // one check-and-capture cycle
}
```
Polls `pasteboard.changeCount` (macOS has no push notification for
pasteboard changes) and, on a real change that passes `PrivacyFilter`,
reads + classifies it via `PasteboardReader` and persists it via
`ClipStore.insertOrBumpDuplicate(_:)`. `checkNow()` is the deterministic
entry point tests drive directly instead of waiting on a real `Timer` — see
`.claude/coding-standards.md`'s testing rules (never a real `Timer`/real
key events in `ClipnestCoreTests`). `ignore(changeCount:)` exists so a
Clipnest-originated pasteboard write (copy-on-select, a synthesized paste)
isn't recaptured as a new external copy on the monitor's next poll — call
it immediately after any write your own code makes, with the pasteboard's
resulting `changeCount`. A store failure during capture is surfaced to
`captureFailureHandler` (default: `os.Logger`, metadata only — case name,
never clipboard content) rather than silently discarded.

---

## Search

Filtering/paging now happens **inside the store**, not client-side:
`ClipStore.query(text:kind:scope:offset:limit:)` and
`SnippetStore.query(text:offset:limit:)` (see [Store](#store) above) do all
the real text/kind filtering, sorting, and pagination as the user types.
`SearchQuery` (below) is a small value type shared with `ClipStore`'s
protocol surface; the standalone `SearchFilter`/`SnippetSearchFilter`
client-side filters that used to do this work in-memory have been deleted
— use the store's `query(...)` methods instead. `SearchHighlighter` is
unrelated to filtering (it only computes highlight ranges for already-
fetched results) and is unchanged.

```swift
public struct SearchQuery: Equatable, Sendable {
  public var text: String
  public var kindFilter: ItemKind?
  public init(text: String = "", kindFilter: ItemKind? = nil)
}
```
A small value type bundling free-text + an optional kind filter. Still
referenced by `ClipStore.fetchAll(matching:)`'s legacy signature (see
[Store](#store)), but `ClipStore.query(...)`/`SnippetStore.query(...)` take
`text`/`kind` as plain parameters directly rather than wrapping them in
this struct — construct one only if you're calling `fetchAll(matching:)`
(which ignores it) or building your own equivalent bundling type.

```swift
public enum SearchHighlighter {
  public static func matchRanges(in text: String, matching query: String) -> [Range<String.Index>]
}
```
Every non-overlapping, case-insensitive occurrence of `query` in `text`,
earliest first — `[]` for an empty query or no match. Pure range-finding,
no `AttributedString`/styling opinion; the app layer (`HighlightedText.swift`)
turns these ranges into a styled view. Useful directly if you're building a
different frontend and want the same "highlight what matched" behavior.

---

## Paste

```swift
public enum PasteContent: Equatable, Sendable {
  case text(String)
  case image(Data)
  case file(URL)
  case richText(rtf: Data, plain: String)
}
```
Content `Paster` places on the pasteboard (and, if possible, pastes into
the previously-frontmost app). `.image` carries image bytes the *caller*
already loaded from `BlobStore` (`Paster` has no `BlobStore` dependency
itself — loading bytes is the caller's job, e.g. `PickerViewModel`). `.file`
carries the file's `URL` (sourced from `ClipItem.fileReference` by the
caller). `.richText` carries RTF bytes plus a plain-text fallback — `Paster`
writes BOTH the `.rtf` and `.string` pasteboard representations (via
`PasteboardWriting.writeRichText(rtf:plain:)`) so a paste target picks the
richest form it supports.

```swift
public struct Paster: Sendable {
  public static let defaultSynthesisDelay: Duration   // 40ms

  public init(
    pasteboard: any PasteboardWriting = NSPasteboard.general,
    eventSynthesizer: any EventSynthesizing = CGEventSynthesizer(),
    isAccessibilityGranted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
    synthesisDelay: Duration = Paster.defaultSynthesisDelay
  )

  public func paste(_ content: PasteContent, targetingFrontmostApp frontmostApp: FrontmostAppRef?) async throws
}

public enum PasteError: Error, Equatable, Sendable {
  case eventPostFailed     // synthesized ⌘V couldn't be created/posted
  case invalidImageData    // .image bytes couldn't be decoded — thrown before any pasteboard write
}
```
Writes `content` to the system pasteboard, then — **only if** Accessibility
is granted (`AXIsProcessTrusted()` by default, injectable for tests) and a
`frontmostApp` target is available — waits `synthesisDelay` and synthesizes
a ⌘V into that app via `EventSynthesizing`. If Accessibility isn't granted,
or no target was provided, `paste(_:targetingFrontmostApp:)` stops cleanly
after the pasteboard write: **no error, no crash** — this is the documented
fallback (see `.claude/coding-standards.md`: "Paster must degrade to
'item on clipboard, no synthesized paste' rather than throw/crash when
Accessibility is missing"). The pasteboard write itself is synchronous,
before any suspension point — read `pasteboard.changeCount` right after
calling `paste` (e.g. to feed `ClipboardMonitor.ignore(changeCount:)`) and
you're guaranteed to observe the write's result even though the method is
`async`.

`.image` bytes are normalized to TIFF via `NSImage(data:)?.tiffRepresentation`
before writing (captured bytes may be PNG or TIFF depending on the source
app; TIFF is what most macOS apps expect for a paste) — undecodable bytes
throw `.invalidImageData` rather than force-unwrapping.

```swift
@MainActor
public final class FrontmostAppTracker {
  public init(provider: any FrontmostAppReferenceProviding = WorkspaceFrontmostAppReferenceProvider())
  public func record()              // capture "who's frontmost right now" — call right before showing the picker
  public func consume() -> FrontmostAppRef?   // returns + clears the recording; last-recorded wins
}
```
Bridges "who was frontmost when the picker was about to open" to "who
should receive the synthesized paste" — `record()`/`consume()` are
deliberately separate calls (not a lazy read at paste time) because the
picker panel doesn't itself steal focus, but focus can still shift
transiently before the user makes a selection.

---

## Error handling

Every module that can fail defines its own `Equatable, Sendable` `Error`
enum with specific cases — no generic `Error`, no `Result<T, Error>`
wrapping (async completion-handler boundaries only, which this package
doesn't have — everything is `async throws`):

| Module | Error type | Cases |
| --- | --- | --- |
| `ClipStore` | `ClipStoreError` | `.notFound`, `.ioFailure(underlying: String)` |
| `SnippetStore` | `SnippetStoreError` | `.notFound`, `.ioFailure(underlying: String)` |
| `BlobStore` | `BlobStoreError` | `.notFound`, `.ioFailure(underlying: String)` |
| `Paster` | `PasteError` | `.eventPostFailed`, `.invalidImageData` |

No force-unwraps (`!`), force-try (`try!`), or force-cast (`as!`) anywhere
in this package's production code — every recoverable failure is a typed
`throw`, and the one genuinely-expected "failure" (missing Accessibility)
is modeled as normal, non-throwing fallback behavior rather than an error
at all (see `Paster.paste` above).

---

## Working example — capture → search → paste, end to end

This mirrors what `ClipnestApp/Sources/App/AppEnvironment.swift` actually
wires together, minus the SwiftUI/AppKit glue. `ClipboardMonitor` and
`FrontmostAppTracker` are both `@MainActor`, so this needs to run in a
main-actor context (e.g. inside your `App`/`AppDelegate`'s own setup) —
`clipStore`/`Paster` themselves have no such restriction:

```swift
import AppKit       // NSPasteboard, referenced directly in step 4 below
import ClipnestCore

// 1. Set up storage — one BlobStore shared by everything that reads/writes blobs.
let blobStore = BlobStore(baseDirectory: BlobStore.defaultBaseDirectory())
let container = try SwiftDataClipStore.makeProductionContainer()
let clipStore: any ClipStore = SwiftDataClipStore(modelContainer: container, blobStore: blobStore)

// 2. Start capturing. ClipboardMonitor polls the real pasteboard, classifies
//    via PasteboardReader, checks PrivacyFilter, and persists via clipStore —
//    all configured with sane defaults; override only what you need to.
let monitor = ClipboardMonitor(store: clipStore, blobStore: blobStore)
monitor.start()

// 3. Search live, in the store, as the user types — the store does the
//    filtering/sorting/paging (offset 0, first page of up to 50 results).
let results = try await clipStore.query(
  text: "invoice", kind: nil, scope: .history, offset: 0, limit: 50)

// 4. Paste the top result back into whatever app was frontmost.
let frontmostAppTracker = FrontmostAppTracker()
frontmostAppTracker.record()   // call this right before showing your picker UI

// ... user picks `results.first` ...
if let item = results.first {
  let paster = Paster()
  try await paster.paste(.text(item.previewText), targetingFrontmostApp: frontmostAppTracker.consume())
  // Tell the monitor this write was ours, not a new external copy:
  monitor.ignore(changeCount: NSPasteboard.general.changeCount)
}
```

For a fully in-memory setup (no SwiftData, e.g. for a test or a script),
swap step 1 for `InMemoryClipStore(blobStore: blobStore)` — it implements
the exact same `ClipStore` protocol.
