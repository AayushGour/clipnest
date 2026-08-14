# Project context — Clipnest

The single source of truth for WHAT + WHY. Authoritative spec (client-approved, wins over this file if they ever disagree):
`docs/superpowers/specs/2026-08-06-clipnest-design.md`. This file summarizes it for the team and adds architect's design/decisions on top.

## Goal
Ship a real, publishable, native macOS clipboard manager the user owns and distributes themselves. The user previously had a free App Store app (`ClipboardManager.app`, dev "abdoo") that is now delisted with no public source — Clipnest is a from-scratch, independent implementation of the generic clipboard-manager category, not a fork or reverse-engineering of that app. It must be local-only (no accounts/network/telemetry), lightest possible footprint (native Swift/SwiftUI, not Electron/Tauri/Rust), and distributed as a notarized direct-download `.dmg`.

## Users
A single macOS power user (the app's owner) who wants fast keyboard-driven access to clipboard history, pinned items, and reusable text snippets, while trusting the app never leaks anything (especially passwords) off-device.

## User stories
- As a user, I want every copy I make to be automatically captured, so I can retrieve it later.
  - AC: Copying text to the pasteboard produces a new `ClipItem` within one polling interval (~0.4s) with correct `previewText` and `kind`.
  - AC: `PasteboardReader` correctly classifies each `ItemKind` (`.text`, `.richText`, `.link`, `.image`, `.file`), verified per-kind in `PasteboardReaderTests`.
- As a user, I want consecutive identical copies to collapse into one entry, so my history isn't cluttered with duplicates.
  - AC: Copying the same content twice in a row updates the existing item (`createdAt`/order moves to top) instead of inserting a duplicate row; verified via `contentHash` equality in `ClipStoreTests`.
- As a user, I want to search my clipboard history by typing, so I can find an old copy quickly.
  - AC: Typing in the picker's search field filters the History list to items whose `previewText` contains the query (case-insensitive), live per keystroke.
  - AC: `SearchQuery`/filtering works standalone against `ClipStore` in `SearchTests`, no UI launch required.
- As a user, I want to paste a selected item directly into the app I was using, so I don't have to manually switch and paste.
  - AC: Selecting an item + Enter writes it to `NSPasteboard.general` and, when Accessibility is granted, synthesizes ⌘V into the previously-frontmost app (verified with a mocked `EventSynthesizing` in `PasterTests`, no real key events in CI).
  - AC: When Accessibility is NOT granted, the item is still placed on the clipboard, the picker closes cleanly, and nothing crashes or hangs — user pastes manually.
- As a user, I want to copy and later retrieve images and files, not just text, so my whole clipboard workflow is covered.
  - AC: Copying an image creates a `ClipItem` (kind `.image`) with bytes written to `BlobStore` at a content-addressed path and `blobPath` set.
  - AC: Copying the same image twice dedups to a single blob on disk (`BlobStoreTests` round-trip).
  - AC: Copying a Finder file reference creates a `ClipItem` (kind `.file`) with enough metadata to re-offer it on paste.
- As a user, I want to pin important items so they never get cleared automatically, so I keep quick access to things I reuse often.
  - AC: Pinning sets `pinned = true`; the item appears in the Pinned tab and is excluded from any retention-cap cleanup.
  - AC: Unpin removes it from the Pinned tab without deleting the underlying item.
- As a user, I want reusable text snippets (not just captured history), so I can quickly insert boilerplate text.
  - AC: Creating a `Snippet` (title/body/optional keyword) persists and appears in the Snippets tab (⌘3).
  - AC: Selecting a snippet pastes its body via the same paste path as a history item.
- As a user, I want the app to never capture sensitive data like passwords, so my secrets stay safe.
  - AC: `PrivacyFilter` rejects any pasteboard change carrying `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType` (`PrivacyFilterTests`), with no setting able to override this.
  - AC: `PrivacyFilter` rejects changes whose source bundle ID is in the built-in password-manager list or the user's custom exclude list.
  - AC: "Pause capture" (menu + Settings) stops all new captures until resumed.
- As a user, I want to configure the app (hotkey, launch at login, exclusions, retention) from Settings, so I can tailor it to my workflow.
  - AC: Settings exposes a `KeyboardShortcuts.Recorder` bound to the picker hotkey (default ⌘⇧V), a launch-at-login toggle wired to `SMAppService.mainApp`, an excluded-apps list (add/remove), storage usage, and a confirmed "Clear history" action.
- As a user, I want an optional cap on how much history is kept, so storage doesn't grow unbounded, while keeping everything by default.
  - AC: With no cap set (default), items accumulate indefinitely — no automatic deletion.
  - AC: With a count/age cap set, unpinned items beyond the cap are deleted (blobs included) on the next cleanup pass; pinned items are never deleted by the cap.

## Business rules
- Dedup is by `contentHash`, not object identity — identical payloads collapse regardless of source app.
- Pinned items are always exempt from any *automatic* cleanup (retention cap). See Assumptions below for the one place this isn't fully specified (manual "Clear history").
- The concealed/transient pasteboard-marker check is absolute — it cannot be disabled by any setting.
- The picker never steals keyboard focus from the underlying app (non-activating `NSPanel`); Accessibility is only ever needed for the *paste* step, never for capture or hotkey.
- Everything is local: no network calls anywhere in the app, structurally enforced (see coding-standards.md Privacy/security musts) not just policy.

## Constraints
- Native Swift 6 + SwiftUI (+ AppKit interop) only — no Rust/Electron/Tauri/web stack. Rejected alternatives and why are in the spec's Goals section.
- Minimum macOS 14.0 (Sonoma) — binding constraint from SwiftData + `SMAppService`.
- Distribution: non-sandboxed, Developer ID signed + notarized `.dmg` (not the Mac App Store — App Store would force sandboxing, which conflicts with the Accessibility/paste-synthesis design).
- **Requires an Apple Developer account ($99/yr)** for the Developer ID certificate + notarization. This is a hard external dependency on the user, not something any task can supply — local build/run/test needs no account; it only blocks the final signing/notarization/DMG milestone (M9 / plan tasks T35–T39).
- Exactly one third-party dependency allowed: `KeyboardShortcuts` (MIT). Everything else is system frameworks.
- Subagent-driven implementation: plan tasks are built by delegated subagents (Sonnet by default; Opus only if a task genuinely requires it), not written inline by the architect.
- Agents run `git add` only — never `git commit`/`git push`; the user authors commits.

## Assumptions / open questions
- **"Clear history" vs pinned items.** The spec states pinned items are exempt from the *automatic* retention cap, but does not explicitly say whether the manual "Clear history" action (Settings) also spares pinned items. Assumption taken for planning: "Clear history" is an explicit, confirmed user action that wipes everything (DB + blobs) including pinned items, matching the spec's literal wording ("wipes DB + blobs"). The Settings UI must show a confirmation dialog before running it. **Flag for client confirmation before T32/T28 (retention + settings) ship** — if pinned items should survive Clear History, that's a small scope change to `ClipStore.clearHistory()`.
- **KeyboardShortcuts version.** The spec doesn't pin a version. Plan defers the exact SPM version pin to implementation time (task T27) — verify the current latest stable release + MIT license on github.com/sindresorhus/KeyboardShortcuts rather than trusting a version number baked into this plan, which may be stale by the time T27 runs.
- **Password-manager bundle-ID seed list.** Coding standards call for a built-in exclude list (1Password, Bitwarden, LastPass, Dashlane, Keeper, etc.); exact current bundle IDs should be verified via web search at T5's implementation time rather than hardcoded from memory.

## Out of scope
- iCloud / cross-device sync.
- Auto-update (Sparkle) — deferred to v1.1.
- Mac App Store build / sandboxed distribution.
- Cross-platform (Windows/Linux).
- RTF/styled-paste fidelity beyond plain text + basic rich text.

---

## Architecture  (architect)
- **Stack:** Swift 6, SwiftUI + AppKit interop, SwiftData, macOS 14+ minimum, XcodeGen for the app project, SPM for the core library.
- **Modules:**
  - `ClipnestCore` (SPM library, no UI, fully unit-testable via `swift test`) — `Model/` (`ClipItem`, `Snippet`, `ItemKind`), `Clipboard/` (`ClipboardMonitor`, `PasteboardReader`, `PrivacyFilter`), `Store/` (`ClipStore` protocol + `SwiftDataClipStore`, `BlobStore`), `Search/` (`SearchQuery`/filtering), `Paste/` (`FrontmostAppTracker`, `Paster`, `EventSynthesizing`).
  - `ClipnestApp` (XcodeGen `.app` target, depends on `ClipnestCore`) — `App/` (`@main`, `MenuBarExtra`, `AppDelegate`), `UI/Picker/` (non-activating `NSPanel` + SwiftUI content), `UI/Settings/` (SwiftUI `Settings` scene), `System/` (hotkey via `KeyboardShortcuts`, launch-at-login via `SMAppService`, `PermissionsManager`).
- **Data model:** `ClipItem { id, createdAt, kind, previewText, contentHash, pinned, sourceAppName?, sourceBundleID?, byteSize, blobPath? }`; `Snippet { id, title, body, keyword?, createdAt }`; `ItemKind` enum `.text/.richText/.link/.image/.file`. Metadata in SwiftData; large payloads content-addressed in `BlobStore` under `~/Library/Application Support/Clipnest/blobs/<hash>`.
- **APIs:** none external — this is a local-only desktop app with no network surface. Internal contracts (protocols) are `ClipStore` (CRUD, dedup, search, pin) and `EventSynthesizing` (injectable for `Paster` testing); both defined in `ClipnestCore`.
- **Full repo tree + exact `project.yml`/`Package.swift` contents:** `docs/superpowers/plans/2026-08-06-clipnest-plan.md`, task T2. `.claude/coding-standards.md` has the condensed folder layout every task must match.

## Team  (architect — from the team-formation self-review)
- **Size:** L (9 milestones, a real distributable macOS app with signing/notarization — set by architect; no PM has tagged size yet this session, revisit with project-manager if that changes).
- **Core roles in play:** architect (this plan), senior-dev (hard/foundational tasks — Core module, paste engine, stores), junior-dev (well-scoped UI/wiring sub-tasks), devops (build/sign/notarize/package scripts), reviewer (per-phase code + mandatory security pass — this app's whole purpose is handling sensitive clipboard content), tester (per-phase AC validation, pasted `swift test` output required before `done`).
- **ux-designer / product-engineer:** not engaged this round. The client-approved spec already fixes the UX flows (menu bar icon, hotkey, picker panel, tabs, keyboard nav, Settings layout) at wireframe-equivalent detail and has already resolved feasibility/stack tradeoffs (native vs Rust/Electron, dependency count, macOS version floor) — there is no fuzziness left to shape and no dedicated `design.md` is needed for v1. Revisit ux-designer only if a specific screen needs a visual pass beyond the spec's description (e.g. actual icon/visual design), and product-engineer only if a genuinely new unknown shows up during build.
- **Specialists added:** none. No ongoing domain gap exists — this is a single-platform native Swift/SwiftUI app, which is within senior-dev's general remit like any other stack (unlike, say, ML/data engineering or a second target platform, which would warrant one). Do not add a "macOS specialist" — that would just be senior-dev under a different name.

## Decisions  (append-only; only if it constrains future work)
### D1 — Repo layout: root SPM package + `ClipnestApp/` as a local-path-dependent XcodeGen project  (2026-08-06, architect)
Why: keeps `swift test` runnable at the repo root with zero Xcode dependency, matching the spec's "fully unit-testable via `swift test`" goal for `ClipnestCore`. Alt: one `.xcodeproj` with an embedded framework target for Core — rejected because it removes CLI-only testability and reintroduces hand-edited pbxproj/workspace files, which XcodeGen exists specifically to avoid. Impact: locks the top-level tree (`Package.swift` at root, `ClipnestApp/project.yml` depending on `..` as a local SPM package) for every future task. Files: `Package.swift`, `ClipnestApp/project.yml`.

### D2 — Test framework: Swift Testing, not XCTest  (2026-08-06, architect)
Why: modern, less boilerplate, first-class SPM support on Swift 6 toolchains, matches the spec's plain `swift test` framing. Alt: XCTest — still viable and more battle-tested, kept only as a documented fallback if a specific AppKit/async interop issue forces it (must be logged as a new decision here if it happens, not silently mixed in). Impact: all `ClipnestCoreTests` use `import Testing` / `@Test` / `#expect` syntax; see coding-standards.md.

### D3 — Formatter/linter: `swift-format`, not SwiftLint  (2026-08-06, architect)
Why: ships with the Swift 6 toolchain (`swift format` subcommand) — zero extra install, keeps the project at exactly one third-party dependency total (`KeyboardShortcuts`). Alt: SwiftLint — more configurable and widely used, rejected because it's a second external tool (Homebrew-installed) against the spec's "lightest footprint / minimal dependencies" goal. Impact: exact lint/format commands are pinned in coding-standards.md; every task must run clean before `review`.

### D4 — Reviewer/tester loop is phase-gated (5 phases), not per-task or single end-of-project  (2026-08-06, architect)
Why: ~28 atomic build tasks make per-task review/test cycles impractically heavy coordination overhead for an L-size project; a single end-of-project review defers defect discovery too long and violates "tester owns done per meaningful increment." Alt: per-atomic-task review (~28 cycles, rejected as overhead) and single final review (rejected, too late to catch issues). Impact: `task-board.md` groups build tasks into 5 phases (A: scaffold+capture, B: picker+paste, C: rich content+pin+snippets, D: hotkey+settings+privacy+retention, E: signing/notarization/DMG), each closed by one reviewer task + one tester task before the next phase's UI work is considered mergeable (build tasks within/across phases can still run in parallel on branches per `deps`).

### D5 — KeyboardShortcuts version pin deferred to implementation time (task T27)  (2026-08-06, architect)
Why: the package was observed at major v6 (per its current SPM manifest) while writing this plan; hardcoding a version now risks staleness by the time T27 actually runs. Alt: pinning a version in `project.yml` today — rejected as likely-stale. Impact: T27's task text requires verifying the current latest stable tag + MIT license against github.com/sindresorhus/KeyboardShortcuts before adding the dependency, then recording the resolved version in `Package.resolved`.

### D6 — Interim non-SwiftData persistence: domain value types + `InMemoryClipStore`, SwiftData deferred behind the store until full Xcode is installed  (2026-08-06, architect; forced by environment, decided on senior-dev's escalation)
**Context / trigger.** SwiftData's `@Model` macro (required by `PersistentModel`; no supported way to conform manually) cannot expand under standalone Command Line Tools — its plugin binary (`SwiftDataMacros.PersistentModelMacro`) ships only inside Xcode.app's toolchain, which is not installed in this environment (verified: `find / -iname '*SwiftDataMacros*'` empty; no Xcode.app via mdfind/`ls /Applications`; corroborated by swiftlang/vscode-swift#1069). Because `swift build` compiles all of `ClipnestCore` as one unit, a single `@Model` use breaks the entire package — blocking `swift test` even for SwiftData-free tasks (T4/T5). This is an unfixable build-tooling/environment limitation, not a product or data-model change; **D1 (SwiftData is the production persistence for `ClipItem`/`Snippet` metadata) still stands.**
**Decision.**
1. `ClipItem`, `Snippet`, `ItemKind` are `Sendable` value types (structs/enum) — the domain models surfaced to all of `ClipnestCore` and `ClipnestApp`. They are NOT `@Model` types. This also fixes a latent Swift 6 strict-concurrency problem: `@Model` classes are not `Sendable` and would fault crossing the `async` `ClipStore` boundary; value types cross cleanly.
2. SwiftData is confined behind the `ClipStore`/`SnippetStore` protocols. The production `SwiftDataClipStore`/`SwiftDataSnippetStore` own a *private* `@Model` entity and map to/from the domain struct — a SwiftData type never crosses the Store boundary. This is the permanent target architecture, not just an interim shim.
3. Until full Xcode.app is installed, the concrete `ClipStore`/`SnippetStore` is the pure in-memory `InMemoryClipStore`/`InMemorySnippetStore` (dictionary-backed; fulfils the exact protocol contract — dedup-by-`contentHash`, CRUD, pin, clear, newest-first `fetchAll`). Fully unit-testable via `swift test` now, and it remains permanently as the canonical in-memory test store. Metadata persistence-across-relaunch is deferred with the SwiftData swap; no throwaway on-disk metadata format is built. `BlobStore` is unaffected — already non-SwiftData disk storage under `~/Library/Application Support/Clipnest/blobs/`, works today.
4. Naming: the interim concrete store is `InMemoryClipStore.swift`, NOT `SwiftDataClipStore.swift` (a `SwiftData…` prefix on an in-memory store violates coding-standards' "prefix names the real backing" rule and misleads review). The plan's file list (T6/T22) is amended accordingly; `SwiftDataClipStore.swift`/`SwiftDataSnippetStore.swift` are created only by the swap task (T40).
**Alternatives rejected.** (A) Block T3/T6/T7 until Xcode is installed — rejected: forfeits all of Phase A's verifiable Core output this session, including T7, for an external dependency with no ETA. (B-plain) Keep `ClipItem`/`Snippet` as plain reference classes and re-add `@Model` to them later — rejected in favour of value types: re-adding `@Model` to the same class touches the whole Model layer and reintroduces the non-`Sendable` concurrency conflict at swap time; the entity/mapping split confines the swap to the Store layer. (C) Adopt Core Data or a hand-rolled store permanently to dodge the macro — rejected: abandons the spec/D1 SwiftData choice for a permanent workaround to a temporary tooling gap.
**Impact.** Unblocks T3, T6, T7 (all Phase A Core) this session; T19/T20/T22/T32 build against the protocol + `InMemoryClipStore`, not SwiftData directly; T8/T9 review/test Phase A against the in-memory store. The eventual SwiftData swap is a single-layer, additive change: task **T40** adds `SwiftDataClipStore`/`SwiftDataSnippetStore` (private `@Model` entity + mapping) behind the unchanged protocols and switches the App's composition root to construct them — no domain type, `ClipboardMonitor`, `SearchFilter`, `Paster`, picker, or settings code changes. T40 is gated on full Xcode being installed (the same env precondition that already defers the whole `ClipnestApp`/XcodeGen build). coding-standards.md Persistence + Naming + layout sections updated to match (architect, this session).
**Files:** `Sources/ClipnestCore/Model/{ItemKind,ClipItem,Snippet}.swift` (value types); `Sources/ClipnestCore/Store/{ClipStore,InMemoryClipStore,SnippetStore,InMemorySnippetStore}.swift`; later `Sources/ClipnestCore/Store/{SwiftDataClipStore,SwiftDataSnippetStore}.swift` (T40).

### D7 — Paster/FrontmostAppTracker decoupled via a plain `FrontmostAppRef?` parameter; `ApplicationServices` added as a used system framework  (2026-08-06, senior-dev, T14/T15)
Why (decoupling): `Paster.paste(_:targetingFrontmostApp:)` takes a plain `FrontmostAppRef?` rather than holding a `FrontmostAppTracker` reference. `FrontmostAppTracker` is `@MainActor` (touches `NSWorkspace`, matching `ClipboardMonitor`'s existing `@MainActor` pattern); `Paster` itself needs no actor isolation (pure pasteboard write + event synth) and shouldn't be forced onto `@MainActor` just to read the tracker. The caller (App-layer `PickerView`/`PermissionsManager`, T16) calls `tracker.consume()` on the main actor and passes the result in — one responsibility per type, no cross-actor coupling baked into `ClipnestCore`. `FrontmostAppTracker.consume()` also clears its recorded value after returning it (not just an accessor) so a stale target from a previous picker session can't leak into a later, unrelated paste.
Why (naming): the new `FrontmostAppReferenceProviding`/`WorkspaceFrontmostAppReferenceProvider` (Paste/, T14) are deliberately distinct names from the pre-existing `FrontmostApplicationProviding`/`WorkspaceFrontmostApplicationProvider` (Clipboard/ClipboardMonitor.swift, T7) — same app, different point in time and different payload (bundle ID + name for capture attribution vs. bundle ID + `pid_t` for `CGEvent postToPid` paste targeting). Kept separate rather than merged/reused to avoid overloading one protocol with two unrelated call sites' needs.
Why (`ApplicationServices`): `Paster`'s default `isAccessibilityGranted` closure calls `AXIsProcessTrusted()`, which needs `import ApplicationServices` (not covered by `AppKit` alone). Coding-standards.md's "everything else is a system framework" list (Foundation, SwiftUI, AppKit, SwiftData, CoreGraphics, UniformTypeIdentifiers, ServiceManagement) predates this need but already calls out `AXIsProcessTrusted` by name under Privacy/security musts — `ApplicationServices` is a first-party macOS system framework, not a new third-party dependency, so it doesn't change the "exactly one third-party dependency" count. Flagged explicitly here for reviewer rather than silently added.
**Impact.** `Paster`'s public API is `paste(_:targetingFrontmostApp:)`, not `paste(_:tracker:)` — T16 (PermissionsManager + picker wiring) must call `frontmostAppTracker.consume()` itself and pass the result. `Sources/ClipnestCore/Paste/{FrontmostAppTracker,EventSynthesizing,Paster}.swift` add `ApplicationServices` to the reviewed-import set.

### D8 — Storage core (T19/T20/T22/T32-Core): blob-writing lives in `ClipboardMonitor`, not `PasteboardReader`; SHA256 hashing consolidated into `BlobStore.contentHash(of:)`; `BlobStore.delete` is idempotent; retention/pin/blob-cleanup semantics  (2026-08-06, senior-dev, T19/T20/T22/T32)

**Blob-writing ownership.** `PasteboardReader.read(from:)` stays a pure, I/O-free classifier: for `.image` it returns the raw image `Data` on the new `Classification.rawData` field (renamed from the old bare tuple return type — same field names, so existing call sites/tests needed no changes beyond the new fields) but never touches `BlobStore` itself. `ClipboardMonitor.checkNow()` (the existing capture-orchestration seam, which already has the `captureFailureHandler` error-surfacing pattern) is the one place that calls `BlobStore.write(_:)` and sets the resulting `blobPath` on the `ClipItem`. Rationale: keeps "classify" and "persist" as separate responsibilities (`PasteboardReader` needs no `BlobStore` dependency at all, so every existing/new `PasteboardReaderTests` case stays 100% filesystem-free), and reuses the failure-surfacing plumbing `ClipboardMonitor` already had instead of inventing a second one inside the reader. Alt considered: inject `BlobStore` into `PasteboardReader` and write there (the literal wording in the routed task spec) — rejected per that same spec's explicit permission to make this call, because it would force every `PasteboardReader` instantiation (including all text/richText/link-only tests) to carry a `BlobStore` dependency it never uses, and would make `read(from:)` `throws` for an I/O reason unrelated to classification. `.file` items never write a blob at all (metadata/reference-only): `previewText` = filename, `contentHash` = hash of the file's URL string, `byteSize` = best-effort real on-disk file size (`FileManager.attributesOfItem`, falls back to `0` if unreadable/missing — never throws).

**Hashing consolidated.** `BlobStore.contentHash(of:)` (`static`) is now the single SHA256-hex implementation in `ClipnestCore`, used by both `BlobStore.write(_:)` internally and by every `PasteboardReader.Classification` case (text/richText/link/image/file) for `ClipItem.contentHash`. `PasteboardReader`'s previously-private `sha256Hex(of:)` was deleted in favor of this — it became a real (not hypothetical) duplicate the moment image/file support needed identical logic, per coding-standards.md's DRY rule.

**Pasteboard type-classification priority extended.** New order: `.fileURL` → image (`.tiff`/`.png`) → `.rtf` → `.string`, most-specific first (previously just `.rtf` → `.string`). Needed because a single pasteboard change commonly carries multiple representations — a Finder file copy often also carries a `.tiff` icon thumbnail and/or a plain-text path string; a browser image copy often also carries a `.string` image URL — so `.fileURL` must never lose to `.tiff`, and image types must never lose to `.string`. Covered by `filePrioritizedOverImageThumbnail` / `imagePrioritizedOverPlainTextRepresentation` tests.

**`BlobStore.delete` is idempotent (unlike `read`).** `delete(blobPath:)` returns normally (no throw) if the file is already gone — deliberately asymmetric with `read(blobPath:)`, which throws `.notFound` on a missing path. Rationale: `read`-ing a dangling `blobPath` signals a genuine data-integrity bug the caller needs surfaced (e.g. a UI trying to render a thumbnail for bytes that no longer exist); `delete`-ing an already-gone blob from a cleanup call site (`ClipStore.delete`/`clearHistory`/`enforceRetention`) achieves the caller's intent trivially and isn't a real failure — matches Unix `rm -f` semantics. `BlobStore.write(_:)`'s own dedup-on-identical-bytes is what actually guarantees "identical images reuse one blob" (not `ClipStore`-level `contentHash` dedup, which only guarantees one `ClipItem` row) — verified directly in `ClipboardMonitorTests.duplicateImageCopiesReuseOneBlob`.

**`ClipStore`/`InMemoryClipStore` now own a `BlobStore` dependency** (defaulted to `BlobStore(baseDirectory: BlobStore.defaultBaseDirectory())` — safe because `BlobStore` does zero I/O at construction, so this default never touches disk in any existing text-only test). `delete(_:)`/`clearHistory()`/`enforceRetention(cap:)` all best-effort-delete every referenced blob via a shared private `deleteBlobs(for:)` helper, collecting individual blob-deletion failures and throwing one summarizing `ClipStoreError.ioFailure` rather than aborting mid-cleanup or swallowing silently — metadata state (`itemsByID`) is always fully updated first, so a blob-cleanup hiccup never leaves the store's own bookkeeping inconsistent. `ClipboardMonitor` similarly defaults its own `blobStore` parameter the same way — **whoever builds the real App composition root (T40 or wherever `ClipboardMonitor`/the concrete `ClipStore` are first wired together in `ClipnestApp`) should inject one explicit, shared `BlobStore` instance into both rather than relying on these independent defaults**, even though both compute the identical default path today.

**`RetentionCap` (T32-Core).** `enum RetentionCap { case maxCount(Int); case maxAge(TimeInterval) }`, lives in `ClipStore.swift` next to `ClipStoreError` (same file-grouping precedent). `enforceRetention(cap:)`: `nil` deletes nothing; pinned items are excluded from the eviction candidate pool entirely (never touched, regardless of cap or how it's set); `.maxCount(n)` deletes the oldest excess unpinned items beyond `n`; `.maxAge(t)` deletes unpinned items older than `t` seconds. The Settings UI half of T32 (App-target cap controls) is explicitly out of scope for this session per the routed task — only the `ClipnestCore` method exists so far.

**`SnippetStore` file split (T22).** Split into `Store/SnippetStore.swift` (protocol + `SnippetStoreError`) and `Store/InMemorySnippetStore.swift` (concrete actor), mirroring `ClipStore`/`InMemoryClipStore` exactly — this follows D6's own file list (which already names both files separately) and coding-standards.md's "one primary type per file" rule, rather than the single-file shorthand (`SnippetStore.swift` only) used in this task's routed summary.

**Files.** New: `Sources/ClipnestCore/Store/{BlobStore,SnippetStore,InMemorySnippetStore}.swift`, `Tests/ClipnestCoreTests/{BlobStoreTests,SnippetStoreTests}.swift`, `Tests/ClipnestCoreTests/TestSupport/ImageFixtures.swift`. Extended: `Sources/ClipnestCore/Clipboard/{PasteboardReader,ClipboardMonitor}.swift`, `Sources/ClipnestCore/Store/{ClipStore,InMemoryClipStore}.swift`, `Sources/ClipnestCore/Model/ItemKind.swift` (doc comment only), `Tests/ClipnestCoreTests/{PasteboardReaderTests,ClipboardMonitorTests,ClipStoreTests}.swift`.

### D9 — Environment unblocked: full Xcode 26.6 now installed; `ClipnestApp` scaffold (T2 App half) built  (2026-08-06, senior-dev, T2)
D6's stated trigger condition ("until full Xcode.app is installed") is now satisfied: `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer` (Xcode 26.6, Swift 6.3.3), `xcodebuild`/`xcodegen` (2.46.0) both work, and bare `swift build`/`swift test` run with no extra flags — the CLT-only `-Xswiftc -F ...` workaround noted in earlier senior-dev log entries is confirmed obsolete. Built the `ClipnestApp` XcodeGen target (T2's previously-deferred App half): `project.yml`, `Sources/App/{ClipnestApp,AppDelegate}.swift`, `Resources/ClipnestApp.entitlements`, `Resources/Assets.xcassets/` — all verbatim per the plan. `xcodegen generate` clean, `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`, `Clipnest.app` present with `LSUIElement=true`. Root `swift build`/`swift test` unaffected (still 85/0) — the local-path SPM dependency in `project.yml` didn't disturb root package resolution.
**Impact.** T2 (App half) is functionally complete and moved to `status:review`. **T40 (SwiftDataClipStore/SwiftDataSnippetStore swap) is no longer environment-blocked** — its `blocked` status on the task board should be revisited (architect/PM call, not made unilaterally here since T40 wasn't the task in scope this session). D6's core decision (domain value types + Store-boundary confinement of SwiftData) still stands as the *permanent* target architecture regardless — only the "interim `InMemoryClipStore`" scoping is now swappable.
**Files:** `ClipnestApp/{project.yml,Sources/App/*,Resources/*}` (new, this session).

### D10 — App composition root + Picker vertical slice (T10/T11-UI/T12): shared `BlobStore` injection, `MenuBarExtra` kept as the trigger, new `PickerViewModel` file, T12 scoped to `.text`/`.link`  (2026-08-06, senior-dev, T10/T11/T12 + composition root)
Built `ClipnestApp/Sources/App/AppEnvironment.swift` as the single composition
root: one `BlobStore` instance constructed once and passed explicitly to both
`InMemoryClipStore(blobStore:)` and `ClipboardMonitor(...blobStore:)` — never
relying on either type's own defaulted `BlobStore` constructor parameter,
which would silently create two independent instances that only agree on
disk paths by coincidence. `AppDelegate` (now `@MainActor`) owns the one
`AppEnvironment` and calls `startCapture()` (real `Timer`,
`ClipboardMonitor.defaultPollInterval`) from `applicationDidFinishLaunching`.
**Menu bar trigger:** kept `MenuBarExtra(.menu)` — no need to fall back to a
raw `NSStatusItem` as the task brief flagged as an allowed contingency; a
plain `Button("Open Clipnest") { appDelegate.showPicker() }` inside the
existing menu triggers the `NSPanel` cleanly. **`PickerPanel` (T10):**
borderless + `.nonactivatingPanel`, `canBecomeKey`/`canBecomeMain` overridden
(a borderless panel defaults both to `false`), `show(at:)` uses
`orderFrontRegardless()` + `makeKey()` — never `NSApp.activate`/
`makeKeyAndOrderFront` — so it can't steal focus from the frontmost app (the
same technique Spotlight-style launcher panels use). **New file beyond the
plan's literal T11 list:** `UI/Picker/PickerViewModel.swift` — the "live
clipboard history" requirement needs a poll `Task` with a stable owner across
SwiftUI view-body re-evaluations; pulling that + T12's copy-on-select logic
into a small `ObservableObject` keeps `PickerView` thin (separation of
concerns), not scope creep. **T12 scoped to `.text`/`.link` kinds only** —
both store their full content verbatim in `ClipItem.previewText` (unlike
`.richText`/`.image`/`.file`, which only store a summary); selecting other
kinds is currently a no-op (flagged as a UX gap for T21, not silently
papered over).
**Impact.** T10/T11(UI)/T12 + the app composition root are functionally
complete, moved to `status:test`. Runtime GUI behavior (non-activation,
live-refresh, actual clipboard write) is unverified in this headless
session — explicitly flagged for reviewer/tester's manual pass, not claimed
as verified.
**Files:** `ClipnestApp/Sources/App/{AppEnvironment.swift (new),
AppDelegate.swift, ClipnestApp.swift}`,
`ClipnestApp/Sources/UI/Picker/{PickerPanel,PickerView,PickerViewModel,
ItemRow}.swift` (all new).

### D11 — Picker fix rounds 1–2: self-write suppression API, T13 keyboard nav, full-screen positioning, `KeyboardShortcuts` pinned to 3.0.1 (not the stale 1.x number) with ⌥⌘V default  (2026-08-06, senior-dev, fix rounds 1–2)
**Round 1 (3 runtime bugs).** (1) Real bug: copy-on-select was being
re-captured as a new history entry because `ClipboardMonitor` couldn't tell
its own pasteboard writes apart from real external copies. Fixed with a new
Core API, `ClipboardMonitor.ignore(changeCount:)` (unit-tested,
`ignoresOwnPasteboardWrite()`), and extended `PasteboardWriting` (already
used by `Paster`) with `changeCount` so today's `PickerViewModel.select(_:)`
write and any future `Paster`-based write share one suppression call site
instead of two bespoke ones. (2) T13 keyboard nav (Esc/↑/↓/⌘F) added via one
`.onKeyPress` on `PickerView`'s container; Return stays on the search
field's existing `.onSubmit` from T12, not duplicated. (3) The picker wasn't
appearing correctly over full-screen apps / wasn't positioned at the cursor:
`PickerPanel.show(at:)` now defaults to `NSEvent.mouseLocation` on the
screen actually containing the cursor (was: centered on a fixed screen),
and `level` was raised `.floating` → `.popUpMenu` (`.floating` sits too low
to draw over another app's full-screen content; `collectionBehavior`
`[.canJoinAllSpaces, .fullScreenAuxiliary]` was already correct from T10).

**Round 2, item 1 (scroll/selection reset).** `PickerViewModel` now
distinguishes a *hard* reset (`selectFirstResult()` — always jumps to the
newest/top result, bumps a new `scrollToTopToken`) from a *soft* one
(`reconcileSelection()` — keeps the current selection if still visible,
only falls back to hard-reset if it vanished). Hard reset fires on the
picker opening (`willShow()`'s query reset, then again once the initial
`reload(resetSelection: true)` completes with fresh data) and on every
search-text keystroke (`query`'s `didSet`); the periodic live-refresh poll
while the picker stays open uses the soft path so it doesn't yank the
user's arrow-key navigation back to the top every ~0.4s. `PickerView` wraps
the `List` in a `ScrollViewReader` and scrolls to the top row whenever
`scrollToTopToken` changes.

**Round 2, item 2 (global hotkey, T27) — version-verification story worth
recording as a process note, not just a result.** Initial `git ls-remote
--tags` + `sort -V | tail -5` reported `v1.10.0` as latest and it was
pinned as such; the build succeeded, but the *resolved* `Package.resolved`
came back as `1.17.0` — SPM's `from:` correctly resolving "latest matching
1.x" — which didn't match what was just verified, a real discrepancy worth
chasing rather than shrugging off. Root cause: the project renamed its tags
from a `vX.Y.Z` prefix to a bare `X.Y.Z` format after `v1.17.0`, and `sort
-V` on the *unfiltered* combined tag list doesn't interleave `"v1.10.0"`
and `"1.11.0"` the way a human would expect — the actual latest stable tag
is a bare `3.0.1` (GitHub releases API `tag_name` confirms), a full major
ahead of what the naive sort found. Re-verified by diffing `Package.swift`,
`Name.swift`, and `Shortcut.swift` between the two majors before pinning:
3.x requires `swift-tools-version:6.2` (fine — Xcode 26.6 ships Swift
6.3.3) and renames `Name.init`'s `default:` parameter to `initial:`
(`default:` still exists but is `@available(*, deprecated)` — updated to
the non-deprecated label rather than shipping a deprecation warning); more
importantly, 3.x makes `Name`/`Shortcut` natively `nonisolated`/`Sendable`,
which *removed* the `@MainActor` workaround the 1.x pin would have needed
for Swift 6 strict concurrency (1.x's `Name` isn't `Sendable`, confirmed by
the initial build actually failing on exactly that error before the version
was corrected). Pinned `from: 3.0.1` in `project.yml`, resolved and
confirmed via the generated `Package.resolved` (gitignored along with the
rest of `ClipnestApp/*.xcodeproj/`, per the existing convention — the pin
of record lives in `project.yml`). `HotkeyManager.swift` defines
`KeyboardShortcuts.Name.togglePicker` with a default of **⌥⌘V**
(Option+Command+V) — a deliberate override of the original spec's ⌘⇧V
default, per explicit routing-message instruction, not an oversight — set
automatically on first launch by the library's own `Name.init` (no manual
"first launch" bookkeeping needed). `AppEnvironment.registerHotkey()`
wires it to the identical `showPicker()` path the menu bar uses.
**Impact.** Both fix rounds are functionally complete, moved to
`status:test`. `KeyboardShortcuts` is `ClipnestApp`-only (root `swift
build`/`swift test` package has no dependency on it, unaffected — still 86
tests green). Full-screen overlay and arrow-key event bubbling from a
focused `TextField` are runtime-only claims per AppKit/SwiftUI's documented
behavior, unverified in this headless session — flagged for a manual pass,
not claimed as proven.
**Files:** `Sources/ClipnestCore/Clipboard/ClipboardMonitor.swift`,
`Sources/ClipnestCore/Paste/Paster.swift`,
`Tests/ClipnestCoreTests/{ClipboardMonitorTests,PasterTests}.swift`,
`ClipnestApp/Sources/UI/Picker/{PickerViewModel,PickerView,PickerPanel}.swift`,
`ClipnestApp/Sources/App/{AppEnvironment,AppDelegate}.swift`,
`ClipnestApp/Sources/System/HotkeyManager.swift` (new),
`ClipnestApp/project.yml`.

### D12 — T40: real SwiftData persistence swapped in behind `ClipStore`/`SnippetStore`; plain `actor`s (not `@ModelActor`); shared `deleteBlobs` helper extracted  (2026-08-06, senior-dev, T40)
D6's permanent target architecture is now live: `SwiftDataClipStore`/`SwiftDataSnippetStore` (`Sources/ClipnestCore/Store/{SwiftDataClipStore,SwiftDataSnippetStore}.swift`) are the production `ClipStore`/`SnippetStore` implementations, each owning a *private*, file-scoped `@Model` entity (`ClipItemRecord`/`SnippetRecord`) that never crosses the protocol boundary — verified by inspection, no `@Model` type appears in any function signature outside those two files. `InMemoryClipStore`/`InMemorySnippetStore` are unchanged and remain the canonical stores for `ClipnestCoreTests`, per D6.
**Plain `actor`, not `@ModelActor`.** `@ModelActor`'s synthesized `init(modelContainer:)` has no room for `SwiftDataClipStore`'s second required dependency (the shared `BlobStore` — see D10's "one shared `BlobStore`" invariant, which still holds). Both stores are hand-written actors storing a `ModelContext` as an actor-isolated property instead; `ModelContainer` (`Sendable`) crosses into `init` cleanly, and actor isolation serializes every context/record access — the same guarantee `@ModelActor` would have provided. `ModelContext.save()` is called explicitly after every mutation rather than relying on autosave timing, so a `fetchAll()` right after a write reliably observes it.
**DRY fix surfaced by the swap.** `SwiftDataClipStore` needed the exact same collect-failures-then-throw-once blob-cleanup logic `InMemoryClipStore` already had privately — a real (not hypothetical) duplicate the moment the second store existed. Extracted to a module-internal free function `deleteBlobs(for:using:)` in `ClipStore.swift`; `InMemoryClipStore` refactored to call it too (verified: its existing test suite passes unmodified).
**Composition root.** `AppEnvironment.init()` is now `throws` (constructing a real on-disk `ModelContainer` is genuinely fallible — disk full, permissions, corrupt store file — and coding-standards.md bans force-try in production code as the alternative). `AppDelegate.applicationDidFinishLaunching` `do/catch`es it: on failure, logs metadata only via `os.Logger(.fault)` (never clipboard content) and calls `NSApplication.shared.terminate(nil)` — there's no safe in-app fallback if persistence itself can't come up, so degrading silently to some other store the user didn't ask for was rejected as worse than a clean, logged quit.
**On-disk location.** `~/Library/Application Support/Clipnest/ClipItems.store` and `.../Snippets.store` — same base-directory family as `BlobStore` (`.../blobs/<hash>`), both derived from the existing `BlobStore.defaultBaseDirectory()` helper rather than a second hardcoded path. Verified this directory doesn't exist yet on the build machine (no prior real GUI launch here) — nothing was at risk.
**No versioned schema/migration plan yet** — flagged for whoever next changes `ClipItemRecord`/`SnippetRecord`'s fields: add a `VersionedSchema`/`SchemaMigrationPlan` at that point rather than editing the `@Model` in place, now that a real on-disk schema exists to migrate *from*.
**Impact.** `swift test` → 113/113 (86 prior + 27 new, mirroring the in-memory suites' exact behavioral cases against `isStoredInMemoryOnly: true` containers). App build: `xcodegen generate` + `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`. No domain type (`ClipItem`/`Snippet`/`ItemKind`), `ClipboardMonitor`, `SearchFilter`, `Paster`, or picker UI code changed — confirms D6's prediction that this swap would be additive and Store-layer-only.
**Files:** `Sources/ClipnestCore/Store/{SwiftDataClipStore,SwiftDataSnippetStore}.swift` (new), `Sources/ClipnestCore/Store/{ClipStore,InMemoryClipStore}.swift` (extended/refactored — shared `deleteBlobs` helper), `Tests/ClipnestCoreTests/{SwiftDataClipStoreTests,SwiftDataSnippetStoreTests}.swift` (new), `ClipnestApp/Sources/App/{AppEnvironment,AppDelegate}.swift`.

### D13 — T16: real paste engine wired app-side; `PermissionsManager`; `@preconcurrency import ApplicationServices` needed for `kAXTrustedCheckOptionPrompt` under Swift 6 strict concurrency  (2026-08-06, senior-dev, T16)
`ClipnestApp/Sources/System/PermissionsManager.swift` (new) wraps the two Accessibility trust APIs: `isGranted` (silent `AXIsProcessTrusted()`, what feeds `Paster`) and `requestAccess()` (prompting `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`, reserved for a future Settings "Grant Accessibility" affordance, T28 — not called from the paste path itself). Deliberately not `@MainActor`: both are plain C-function passthroughs and `Paster`'s injected `isAccessibilityGranted` is itself `@Sendable`/non-isolated, so keeping `PermissionsManager` non-isolated avoids an actor hop at the one call site (`AppEnvironment`'s `Paster(isAccessibilityGranted: { PermissionsManager.isGranted })`).
**Build fix, worth flagging for anyone touching `ApplicationServices` next:** referencing `kAXTrustedCheckOptionPrompt` (an `extern CFStringRef` imported as a global `var`) failed Swift 6 strict concurrency with "not concurrency-safe because it involves shared mutable state" — `ApplicationServices`/`HIServices` predates concurrency auditing. Fixed with `@preconcurrency import ApplicationServices` on that one file (narrowly scoped, not a project-wide relaxation) rather than `nonisolated(unsafe)`-wrapping the constant, since the whole framework is unaudited, not just this one symbol.
**Wiring.** `AppEnvironment` now owns `paster: Paster` (real `CGEventSynthesizer`/`NSPasteboard.general` defaults, `isAccessibilityGranted` fed from `PermissionsManager.isGranted`) and `frontmostAppTracker: FrontmostAppTracker`, both constructed once and injected into `PickerViewModel`. `AppEnvironment.showPicker()` — the single choke point both the ⌥⌘V hotkey and the menu bar's "Open Clipnest" already route through (`AppDelegate.showPicker()`) — now calls `frontmostAppTracker.record()` immediately before `pickerPanel.show()`, so neither trigger path needs its own record() call. `PickerViewModel.select(_:)` (T12's stub) now calls `frontmostAppTracker.consume()` then `paster.paste(.text(item.previewText), targetingFrontmostApp:)` instead of writing `NSPasteboard` directly; a thrown `PasteError` is caught and logged (case name only, never content) rather than propagated — the pasteboard write already happened before any throw, so the item is still on the clipboard and this is not fatal. `suppressOwnPasteboardWrite` (self-write suppression, D11) now runs right after `paster.paste()` returns instead of right after a direct pasteboard write — reads `pasteboard.changeCount` off `PickerViewModel`'s own injected `PasteboardWriting`, which resolves to the same real `NSPasteboard.general` singleton `Paster`'s default writes to in production, so the changeCount read is accurate. `.text`/`.link` remain the only pasteable kinds (T21 adds richer kinds) — unchanged guard from T12.
**No test added for `PermissionsManager`** — per the plan's own T16 spec ("thin AppKit wrapper — smoke-level; the branching logic it feeds is already covered by T15's `PasterTests`") and matching `HotkeyManager`'s identical precedent (D11): a direct two-call passthrough with no pure branching logic of its own to unit test.
**Impact.** `swift test` → 113/113 unchanged (no `ClipnestCore` files touched — `Paster`/`FrontmostAppTracker` were already built+tested in T15/T14). `xcodegen generate` + `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` (clean rebuild) → `** BUILD SUCCEEDED **`, zero warnings on touched files. `swift format lint --recursive --strict ClipnestApp/Sources Sources Tests` clean.
**Manual-only, flagged not claimed:** the real end-to-end paste (Accessibility granted → synthesized ⌘V lands in the previously-frontmost app) and the not-granted clipboard-only fallback are both runtime-only checks, unverified in this headless session. Also: this is an ad-hoc/unsigned dev build, so macOS's TCC keys Accessibility grants to the binary's code signature — expect to have to re-grant Accessibility in System Settings after every rebuild during manual testing, not a bug.
**Files:** `ClipnestApp/Sources/System/PermissionsManager.swift` (new), `ClipnestApp/Sources/App/AppEnvironment.swift` (extended), `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift` (extended).

### D14 — T24 pin-order fix: `ClipItem.pinnedAt` added; pinned group sorts by pin time ascending, not `createdAt`; addresses D12's migration flag with a real case  (2026-08-10, senior-dev, T24 amendment)
Bug: the picker's pinned group inherited `createdAt` (copy time) ordering
from the single upstream filter pass, so a newly-pinned item landed
wherever its *copy* time put it among other pinned items instead of
predictably at the end. Fixed by adding a genuine pin-time field and
sorting by it — see the T24 report's "Pin-order fix" section for full
detail; summarized here as the decision record.

**New field, additive/non-breaking.** `ClipItem.pinnedAt: Date?` (`nil`
unless pinned), a defaulted initializer parameter inserted after `pinned`
— every existing call site (`ClipboardMonitor`, both stores' record
mapping, every test's item-builder helper) kept compiling unchanged.
`ClipStore.setPinned(_:pinned:)` sets it (`Date()`) on pin, clears it
(`nil`) on unpin, in **both** `InMemoryClipStore` and `SwiftDataClipStore`
identically — `insertOrBumpDuplicate`'s dedup-bump path needed no change
in either store since it only ever overwrites `createdAt` on an existing
row, preserving `pinnedAt` (and `pinned`) the same way it already did.

**Directly closes D12's flag.** D12 explicitly flagged: "add a
`VersionedSchema`/`SchemaMigrationPlan` [for `ClipItemRecord`] the next
time its fields change, now that a real on-disk schema exists to migrate
from." This is that next change, and a versioned migration plan was
deliberately judged unnecessary *for this specific case*: `pinnedAt` is a
**new optional** property with no default-value conflict and no type
change to any existing property — exactly the shape SwiftData's
lightweight/automatic migration handles with zero configuration (existing
on-disk rows simply read back with `pinnedAt == nil`). Confirmed by
`SwiftDataClipStoreTests` continuing to pass against `ClipItemRecord`'s
updated schema with no migration error. **D12's flag still stands as
general guidance** for a *future* change that isn't purely additive-optional
(a required field, a type change, a rename, a removal) — that's the case
that would actually need a `VersionedSchema`/migration plan; this one
didn't qualify.

**Ordering, App layer only.** `PickerViewModel.items`'s pinned run is now
`.sorted { (lhs.pinnedAt ?? .distantPast) < (rhs.pinnedAt ?? .distantPast) }`
— ascending, so earliest-pinned sits at the top of the pinned group and the
most-recently-pinned sits at the bottom, just above the unpinned run
(unchanged: still newest-first by `createdAt`, inherited for free from the
already order-preserving filter chain). `nil` (can't occur going forward,
but a defensive fallback for any pinned row that somehow predates this
fix) sorts via `Date.distantPast` rather than a separate branch.
`Array.sorted(by:)`'s stability means pinned items sharing an exact
`pinnedAt` keep their prior relative order.

**Deliberately not touched:** `ClipStore.fetchPinned()`'s own sort (still
`createdAt` descending, in both stores) — it backs the not-yet-built
Pinned tab, a separate task; the instruction scoped this fix to
`PickerViewModel`'s ordering specifically.

**Impact.** `swift test` → 117/117 (113 prior + 4 new: a
`setPinned`-sets/clears-`pinnedAt` test and a pin→unpin→re-pin-cycle test,
one matching pair each in `ClipStoreTests`/`SwiftDataClipStoreTests`).
`xcodegen generate` + `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` →
`** BUILD SUCCEEDED **`. `swift format lint --recursive --strict Sources
Tests ClipnestApp/Sources` clean. The picker's actual on-screen ordering
after a live pin/unpin is a manual-runtime-check claim, not verified in
this headless session — the store-level `pinnedAt` behavior is what's
unit-tested here.
**Files:** `Sources/ClipnestCore/Model/ClipItem.swift`,
`Sources/ClipnestCore/Store/{InMemoryClipStore,SwiftDataClipStore}.swift`,
`Tests/ClipnestCoreTests/{ClipStoreTests,SwiftDataClipStoreTests}.swift`,
`ClipnestApp/Sources/UI/Picker/PickerViewModel.swift`.

### D15 — T23: Pinned + Snippets tabs; Pinned filters client-side from `allItems` (not `fetchPinned()`); one shared paste path + one generic scroll-resetting list for both `ClipItem`s and `Snippet`s  (2026-08-10, senior-dev, T23)
Picker-UI wiring only — `ClipStore`/`SnippetStore` already had everything
(`fetchPinned()`, full `Snippet` CRUD). No `ClipnestCore` touched;
`swift test` stayed 117/117.

**Tab model.** New `TabSwitcher.swift`: `enum PickerTab { .history, .pinned,
.snippets }` + a plain click-driven segmented control. ⌘1/⌘2/⌘3 wired into
`PickerView`'s existing single `.onKeyPress` handler (alongside, not
replacing, Esc/↑/↓/⌘F/⌘P/Delete/⌘⌫) — one `PickerTab` binding is the single
source of truth for both click and keyboard tab-switching.

**Pinned tab filters `allItems` client-side, not a second
`ClipStore.fetchPinned()` call** — the task explicitly allowed either.
`PickerViewModel.items` factored into `pinnedRun`/`unpinnedRun` (both from
a shared `filteredItems`); `.history` → `pinnedRun + unpinnedRun` (T24's
pin-order-fixed behavior, unchanged), `.pinned` → `pinnedRun` alone. Both
tabs reading the *same* `pinnedRun` value means their pin ordering is
identical **by construction**, not by two implementations happening to
agree. `togglePin(_:)`/`delete(_:)` bodies are textually unchanged from
T24 — only the shared selection/ordering helpers they call into
(`items`/`highlightedItem`/`reconcileSelection`/`selectFirstResult`)
became tab-aware, so "row actions work on the Pinned tab too" and
"unpinning removes it from that tab" both fall out for free.

**Snippets tab** (`SnippetFormView.swift`, `SnippetRow.swift`, new): one
form (title/multiline body/optional keyword) serves both create and edit
via a `SnippetFormMode` enum, presented as `.sheet(item:)`. Selecting a
snippet pastes `body` through the *exact* mechanism History items use —
see "One shared paste path" below. **No live polling for Snippets**
(design decision): unlike the system pasteboard, nothing outside the
picker mutates snippets while it's open, so a load-on-open + reload-after-
each-CRUD-call is sufficient; a periodic poll (History's pattern) would be
wasted work. Snippets search (title/body/keyword) is a small
self-contained filter, not forced through the `ClipItem`-shaped
`SearchFilter` (which carries an `ItemKind` concept `Snippet` has none of).

**One shared paste path (explicit "don't duplicate" instruction).**
`select(_:)` (`ClipItem`) and the new `pasteSnippet(_:)` (`Snippet`) both
now call one private `pasteAndDismiss(_ text: String)` — the `Paster`
write + self-write-suppression + dismiss logic that used to live only in
`select(_:)`'s body.

**Two more real-duplicate extractions, made during this task rather than
left in place:** a generic `private static func
clampedIndex<Element: Identifiable>(currentID:in:delta:)` on
`PickerViewModel` (used by `moveSelection(by:)` for both `ClipItem`s and
`Snippet`s instead of one hand-written copy per type), and a generic
`private struct ScrollResettingList<Data, ID, RowContent>` in
`PickerView.swift` (the `ScrollViewReader`+`List`+scroll-to-top shape,
shared by the ClipItem list and the new Snippets list instead of
copy-pasted a second time). `ItemRow.swift`'s `RowActionButton` (T24) was
changed from `private` to internal so `SnippetRow.swift` could reuse the
same hover-color icon-button component for Edit/Delete instead of a second
copy.

**`PickerViewModel.init` gained a required `snippetStore: any
SnippetStore` parameter** (no default — matches `clipStore`'s existing
"essential store, mandatory" precedent, unlike `paster`/`frontmostAppTracker`,
which have safe concrete defaults). `AppEnvironment` was the only call
site; updated to capture `snippetStore` into a local `let` first (mirroring
the existing `clipStore` pattern) so it could be passed through.

**Design calls flagged, not silently picked:** reopening the picker does
NOT reset `activeTab` back to History (keeps whichever tab was last
active, matching ordinary tabbed-UI expectations); `query` (search text)
is NOT cleared on tab switch (only selection/scroll reset via the same
`selectFirstResult()` fix-round-2 already uses for "opened"/"search
changed" — reused again here for "tab switched," zero new scroll code);
⌘P is a no-op on the Snippets tab (no pinned concept there); snippet
delete has no confirmation dialog, matching `ClipItem` delete's existing
no-confirmation precedent for UX consistency within the same picker.

**Impact.** `swift test` → 117/117 unchanged (zero Core files touched).
`xcodegen generate` + `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` →
`** BUILD SUCCEEDED **` (one line-length lint finding on first pass in the
new generic `ScrollResettingList` declaration, fixed via `swift format
format --in-place` — pure formatting, rebuilt clean afterward). `swift
format lint --recursive --strict ClipnestApp/Sources Sources Tests` clean.
Tab switching, the create/edit sheet's presentation against a borderless
`NSPanel`, snippet persistence/paste end-to-end, and Pinned-tab row actions
are all runtime-only claims, unverified in this headless session — flagged
in the T23 report, not claimed as proven.
**Files:** `ClipnestApp/Sources/UI/Picker/{TabSwitcher,SnippetFormView,
SnippetRow}.swift` (new), `ClipnestApp/Sources/UI/Picker/{PickerViewModel,
PickerView,ItemRow}.swift` (extended), `ClipnestApp/Sources/App/AppEnvironment.swift`
(extended).

### D16 — T23 fix round: `Paster.paste` becomes `async` (global HID-tap ⌘V posting + a real pre-synthesis delay, replacing pid-targeted posting); Accessibility now prompts on an actual paste attempt; Return-to-paste hardened with a belt-and-suspenders `.onKeyPress(.return)`  (2026-08-10, senior-dev, T23 fix round)
Three items, all picker-layer; tabs/snippets/single-search-box behavior
(query persists across tabs, each tab filters only its own content)
confirmed unchanged — verified by inspection, not re-touched.

**1. Return not pasting.** The search field already had `.onSubmit {
viewModel.selectHighlighted() }` wired (the literal fix the routing
message described) — real-world testing found it still didn't work, and
this headless environment can't independently confirm which of two
plausible SwiftUI event-routing explanations was the actual cause. Added
an explicit `case .return: viewModel.selectHighlighted(); return .handled`
to the same `.onKeyPress` handler that already owns Esc/↑/↓/⌘F/⌘P/⌘⌫/⌘1-3.
Returning `.handled` means this case can't double-fire alongside
`.onSubmit` for the same keypress — SwiftUI won't deliver a `.handled`
event to a second consumer — so whichever mechanism actually wins on a
given macOS version, exactly one fires, and no plausible root cause is
left unaddressed.

**2a. Accessibility now prompts on an actual paste attempt.** New
`PermissionsManager.isGrantedPromptingIfNeeded()` (`isGranted ||
requestAccess()`) replaces the silent `isGranted` as what `AppEnvironment`
feeds `Paster`. Still returns `false` synchronously either way (a grant
never takes effect mid-call), so the *triggering* paste still degrades to
clipboard-only — only a later attempt, after the user grants access in
System Settings, gets the real synthesized paste. No new call site needed
to keep this "paste-attempt-only, never launch": `Paster`'s
`isAccessibilityGranted` closure was already, and remains, invoked
exclusively from inside `paste(_:targetingFrontmostApp:)`.

**2b. `CGEventSynthesizer` switched from `CGEvent.postToPid(_:)` to
`CGEvent.post(tap: .cghidEventTap)`** (global HID event tap — an
injected-as-if-real keystroke, not targeted at a specific process) — a
real behavioral shift, not cosmetic: pid-targeted posting bypasses normal
window-server focus routing, while a globally-injected keystroke goes to
whatever currently holds key focus. This is *why* `Paster.paste` is now
`async throws` (was `throws`) with a new injectable `synthesisDelay:
Duration` (default `Paster.defaultSynthesisDelay = .milliseconds(40)`,
named per coding-standards.md's no-magic-numbers rule) — waited via `try?
await Task.sleep(for:)` after the pasteboard write and the
accessibility/target guard, before calling the synthesizer, so only the
actual-synthesis path pays the delay, never the clipboard-only fallback.
**`PickerViewModel.pasteAndDismiss(_:)` reordered to call `dismiss()`
*before* the async `paster.paste(...)`** (previously last) — this is the
piece that makes the delay actually correct: since posting is now global
rather than pid-targeted, if Clipnest's own panel still held key focus
when the synthetic ⌘V posts, the OS could deliver it into *our own* search
field instead of the target app. Self-write suppression
(`suppressOwnPasteboardWrite`) still runs right after `paster.paste(...)`
returns, now inside the `Task` that awaits it — `Paster.paste`'s doc
comment explicitly notes the pasteboard write itself happens synchronously
before any suspension point, so reading `changeCount` after the full
(possibly-delayed) call still observes the correct value.
**`PasterTests.swift`** updated for the async signature (`async throws`
tests, `await #expect(throws:)`), every test passing `synthesisDelay:
.zero` so the suite stays fast/deterministic rather than sleeping ~40ms
per granted-path test — same "no real timers in tests" convention already
established for `ClipboardMonitorTests`.
**Known, accepted minor risk, documented not ignored:** the gap between
`Paster`'s pasteboard write and `PickerViewModel` reading its
`changeCount` for suppression grew from near-instant to up to
~`synthesisDelay` longer, in the synthesis-granted path only. Given
`ClipboardMonitor`'s ~400ms poll interval is ~10× that gap, the odds of an
unlucky self-recapture race are low but no longer negligible. Not
engineered further against (would need splitting `Paster`'s API into
separate write/synthesize calls, a bigger change than asked for a rare
edge case) — flagged instead.

**3. Always-visible, tab-aware keyboard-shortcut hint footer** (new
`shortcutHintBar`/`shortcutHints` in `PickerView.swift`) — muted
`.caption2`/`.secondary`, always rendered, not hover-gated. History/Pinned:
`↑↓ move · ⏎ paste · ⌘F search · ⌘P pin · ⌘⌫ delete · ⌘1/2/3 tabs · esc close`;
Snippets swaps `⌘P pin` for `⌘N new` (no pinned concept for snippets).
⌘N wired into the same `.onKeyPress` handler, guarded to the Snippets tab,
calling the same `presentCreateSnippetForm()` the existing (already built
in T23) "+" button uses — no new create-affordance needed, just a second
path to it.

**Impact.** `swift test` → 117/117 unchanged. `xcodegen generate` +
`xcodebuild ... CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
`swift format lint --recursive --strict ClipnestApp/Sources Sources Tests`
clean. Every claim about actual runtime behavior in this round (Return
pasting on every tab, the Accessibility dialog actually appearing, the
40ms delay being sufficient/correct, the synthetic keystroke landing in
the right app, the footer rendering correctly) remains unverified in this
headless session — flagged explicitly in the T23 report's fix-round
section, not claimed as proven; this round grew that list, since two of
its three items are inherently runtime-dependent (global keystroke timing,
a system permission dialog).
**Files:** `Sources/ClipnestCore/Paste/Paster.swift`,
`Tests/ClipnestCoreTests/PasterTests.swift`,
`ClipnestApp/Sources/System/PermissionsManager.swift`,
`ClipnestApp/Sources/App/AppEnvironment.swift`,
`ClipnestApp/Sources/UI/Picker/{PickerViewModel,PickerView}.swift`.

### D17 — T23 fix round 2: snippet editor moved off `.sheet()` onto its own activating `NSWindow` (`SnippetEditorWindow`); "Save as Snippet"; snippet fields collapsed to Tag+Body only (Tag maps onto `Snippet.title`, `keyword` left unused); search-match highlighting via a new Core `SearchHighlighter`  (2026-08-10, senior-dev, T23 fix round 2)
Five items, all picker/snippet-layer. `swift test` → 128/128 (117 + 11 new).

**1. Real bug, root-caused and fixed:** the snippet create/edit form was a
SwiftUI `.sheet()` attached to `PickerPanel` — a `.nonactivatingPanel`
whose owning app deliberately never activates (T10's whole
don't-steal-focus mechanism). A sheet's window is a normal window under
the hood and only gets true key status when its owning app is frontmost;
since Clipnest never activates, the sheet could show but never actually
receive typed input or ⌘V paste. Fixed with new
`ClipnestApp/Sources/UI/Picker/SnippetEditorWindow.swift`: a plain titled
`NSWindow` (not a panel), `NSApp.activate()` + `makeKeyAndOrderFront(nil)`
on `show(...)`. Deliberately breaks the picker's own non-activation rule
for this one, different UX moment — the user explicitly clicked "+"/Edit
to type into a form, unlike the picker's passive glance-and-select flow,
so activating here is expected (same as any accessory-policy menu-bar
utility's own Preferences window). `NSApp.activate()` (not the
`ignoringOtherApps:` overload, deprecated as of macOS 14 — our exact
deployment floor) is the modern replacement, used deliberately.
**Real initializer bug found+fixed along the way, worth flagging for
future `NSWindow`/`NSPanel` subclasses:** a `convenience init()` calling
`self.init(contentRect:styleMask:backing:defer:)` failed to compile —
declaring `required init?(coder:)` (needed for `NSCoding`, same as
`PickerPanel`) breaks Swift's automatic inheritance of `NSWindow`'s own
designated initializer, so a convenience init can't reach it via
`self.init(...)` anymore. Fixed identically to `PickerPanel`'s existing
pattern: make `init()` itself the designated initializer, calling
`super.init(...)` directly instead of delegating via `self.init(...)`.
`windowWillClose(_:)` fires one `onClose` callback regardless of how the
window closed (Save/Cancel/red button/⌘W); `AppEnvironment` uses it to
re-key `PickerPanel` + refocus its search field
(`PickerViewModel.refocusSearchField()`, new) so the user lands back in a
usable picker.
`PickerViewModel`'s `@Published snippetFormMode`/`dismissSnippetForm()`
are gone, replaced by an injected `presentSnippetEditor: (SnippetFormMode)
-> Void` closure `AppEnvironment` wires directly to the window —
`presentCreateSnippetForm()`/`presentEditSnippetForm(_:)` keep their exact
names/call sites, only the implementation changed.

**2. "Save as Snippet"** — `ItemRow`'s context menu only (not a third
always-visible hover button; T24 explicitly fixed the trailing controls at
exactly two, so a third here would contradict that), `.text`/`.link` items
only, plus ⌘S in the existing key handler + hint footer. New
`SnippetFormMode.createFromClip(String)` prefills Body, leaves Tag for the
user.

**3. Field correction (arrived mid-implementation, before anything shipped):**
the routing message originally asked for Title+Tag+Body; a follow-up
correction redefined the form to **exactly two fields, Tag and Body** — no
separate Title. Tag maps onto the existing `Snippet.title` (chosen because
`title` was already the field `SnippetRow`/sorting/etc. treat as the
primary label — a UI-label rename, not a new mapping decision);
`Snippet.keyword` is left permanently `nil` by this form — no schema
change, matching the correction's explicit instruction. Confirmed: the
editor's body shows only a `TextField("Tag", ...)` and a `TextEditor`
(Body) — no Title field. `SnippetRow`'s old keyword badge was removed
outright (dead code the moment keyword became permanently nil) rather than
left as inert conditional logic.

**4. Snippets search = Tag OR Body.** Extracted from an inline
`PickerViewModel` closure into `Sources/ClipnestCore/Search/SnippetSearchFilter.swift`
(mirrors `SearchFilter`'s role for `ClipItem`s; `Snippet` has no
`ItemKind` equivalent so this is its own small type, not a forced
generalization) — dropped the `keyword` branch it originally had, since
keyword is unreachable now. 6 new Core tests.

**5. Search-match highlighting** — pure range-finding in new
`Sources/ClipnestCore/Search/SearchHighlighter.swift`
(`matchRanges(in:matching:)`, no `AttributedString`/SwiftUI dependency, 5
new Core tests), presentation in new App-layer
`ClipnestApp/Sources/UI/Picker/HighlightedText.swift` (subtle
accent-tinted background + `.primary` foreground on matched runs — chose
background-only over "bold+accent" specifically to avoid a font-size
mismatch across `ItemRow`/`SnippetRow`'s different text roles, since
unmatched runs correctly inherit whatever font/color the caller already
applies externally). Wired into `ItemRow`/`SnippetRow` via a new `query:
String` parameter each now takes.

**Impact.** `swift test` → 128/128. `xcodegen generate` + `xcodebuild ...
CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **` (clean, from-scratch
rebuild). `swift format lint --recursive --strict ClipnestApp/Sources
Sources Tests` clean. **Item 1's actual fix — does typing/⌘V paste really
work in the new editor window — is the single most important unverified
claim in this whole task**, flagged explicitly as the top concern in the
T23 report rather than assumed to work just because the design reasoning
is sound and it compiles.
**Files:** `ClipnestApp/Sources/UI/Picker/{SnippetEditorWindow,
HighlightedText}.swift` (new), `Sources/ClipnestCore/Search/{SearchHighlighter,
SnippetSearchFilter}.swift` (new), `Tests/ClipnestCoreTests/{SearchHighlighterTests,
SnippetSearchFilterTests}.swift` (new), `ClipnestApp/Sources/UI/Picker/{SnippetFormView,
SnippetRow,ItemRow,PickerView,PickerViewModel}.swift` (extended),
`ClipnestApp/Sources/App/AppEnvironment.swift` (extended).

### D18 — T41/T42 (routed picker follow-up): History and Pinned become mutually exclusive tabs; `ItemRow` gains a third always-visible convert-to-snippet button reusing the existing "Save as Snippet" action  (2026-08-10, senior-dev, T41/T42)
Two small, independently-delegated picker-UI changes, both App-layer only (zero `ClipnestCore` touched); `swift test` stayed 128/128 throughout.

**T41 — History excludes pinned.** `PickerViewModel.items`'s `.history` case now returns `unpinnedRun` alone (was `pinnedRun + unpinnedRun`); `.pinned` is unchanged (`pinnedRun`, sorted `pinnedAt` ascending per D14). This reverses D15's original "History = pinned-first" design: pinning an item now moves it **out of** History's `items` entirely (it only shows in Pinned), and unpinning moves it back — not just a re-sort within one shared list. `togglePin(_:)`'s existing soft-reconciliation reload (`reload(resetSelection: false)`) already handles both directions correctly with no new code, since it was already written generically as "keep selection if still visible in the current tab, else fall back to first result." Search-within-History-over-unpinned-only falls out for free (`unpinnedRun` is already derived from the query-filtered `filteredItems`).

**T42 — third row button, convert-to-snippet.** `ItemRow`'s `rowActions` gained a third `RowActionButton` (order: pin, convert-to-snippet, delete) between the pre-existing pin/delete pair — reversing T24's "the trailing controls are now exactly two" / T23 fix round's "not a third always-visible icon button" decisions, both explicitly noted in-file rather than silently overwritten. The new button is not a new action: it calls the exact same `onSaveAsSnippet` closure the context menu's "Save as Snippet" item already invoked, uses the same SF Symbol (`text.badge.plus`, matching the context-menu icon rather than the `note.text.badge.plus` alternative floated in the routing brief — one icon per action, not two), and is gated by the same `supportsSaveAsSnippet` (`.text`/`.link` only) the context-menu item already used — a `.richText`/`.image`/`.file` row still renders exactly two buttons (pin, delete), not a third that would silently no-op. Context menu itself is unchanged (already had this item, already in this exact order). The shortcut-hint footer already listed `⌘S save` for History/Pinned before this task — confirmed sufficient, left untouched (no duplicate hint added).

**No new automated test coverage for either change** — both are pure `ClipnestApp` SwiftUI/ViewModel edits with no `ClipnestCore` logic change, and this project has no App-level test target wired into `swift test` (per coding-standards.md's "UI kept thin... light smoke tests only" and matching precedent set by T11/T13/T21/T23/T24, none of which added ViewModel/View-level tests for App-only changes). Flagged, not silently skipped. The actual visual result — three buttons rendering in order with correct hover colors, and History genuinely hiding pinned items at runtime — remains a manual GUI check for the human, same category of unverified-in-headless-session claim as prior rounds (D10/D11/D15/D16/D17).

**Delegation.** Split into two independent, disjoint-file tasks and run in parallel: junior-dev A → T41 (`PickerViewModel.swift` only), junior-dev B → T42 (`ItemRow.swift` only). Both reviewed by senior-dev (read full diffs, re-ran `swift test` + `swift format lint --strict` myself) before handoff to tester, who independently re-ran the full build+test+lint suite and confirmed via static read of the same two files.

**Impact.** `swift test` → 128/128 unchanged (matches pre-change baseline exactly). `xcodegen generate` + `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`. `swift format lint --recursive --strict ClipnestApp/Sources Sources Tests` clean. Report: `.superpowers/sdd/2026-08-06-clipnest-plan/task-history-snippet-btn-report.md`.
**Files:** `ClipnestApp/Sources/UI/Picker/{PickerViewModel,ItemRow}.swift` (extended). `SnippetRow.swift`/`PickerView.swift` deliberately not touched (confirmed by tester via file-modification-time check + read).

### D19 — T21 (rich content previews + type-filter chips + non-text paste) plus a routed ⌘⌫ delete-key fix; 5-way junior-dev split across 3 sequential/parallel rounds, senior-dev fixed one silent-error-swallow gap directly before tester  (2026-08-10, senior-dev, T21 + routed ⌘⌫ fix)

Completes plan task **T21** in full (previews + chips + non-text paste, all three parts of its original scope) plus one unrelated, separately-routed bug fix. Orchestrated as 5 junior-dev sub-tasks in 3 rounds, scheduled by file-touch analysis rather than by feature boundary, since `PickerView.swift`/`PickerViewModel.swift` are shared across most of this work and the coordination brief required same-file tasks to serialize:

- **Round 1 (parallel, disjoint files):** ⌘⌫ delete-key fix (`PickerPanel.swift`+`AppEnvironment.swift` only — `PickerViewModel.deleteHighlighted()` already existed, so this needed zero `PickerView.swift`/`PickerViewModel.swift` changes) and the Core `PasteContent` extension (`Paster.swift`+`PasterTests.swift` only, zero App-target files) — genuinely independent, ran together.
- **Round 2 (solo):** rich per-kind row previews (`ItemRow.swift`, `PickerView.swift`, `PickerViewModel.swift`, new `ItemThumbnailCache.swift`, `AppEnvironment.swift`) — had to follow Round 1 since it extends `AppEnvironment.swift` right after the ⌘⌫ fix touched it.
- **Round 3 (parallel again):** type-filter chips (new `TypeFilterChips.swift` + `PickerView.swift` only — turned out to need **zero** `PickerViewModel.swift` changes, since `SearchQuery.kindFilter` already existed and `PickerView` already binds straight into `viewModel.query`'s sub-fields via SwiftUI's dynamic-member-lookup `Binding`, exactly like the pre-existing `$viewModel.query.text` search field — selecting a chip gets `didSet { selectFirstResult() }` for free) and the paste-path wiring (`PickerViewModel.swift` only — `select(_:)` now calls a new `pasteContent(for:)` mapping `ItemKind` → `PasteContent`). These two ended up touching disjoint files (`PickerView.swift` vs `PickerViewModel.swift`), so — despite both needing to run after Round 2 — they could run in parallel with each other, a scheduling win not obvious from the task list alone.

**⌘⌫ fix mechanism.** Same bug family as D16's Return-key issue (the always-focused search `NSTextField`'s field editor consumes the keystroke before SwiftUI ever sees it), but this time fixed at the AppKit layer instead: `PickerPanel` installs a local `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` in `configure()` that matches `event.window === self` + `keyCode == 51` (`kVK_Delete`) + Command in `modifierFlags`, calls a new `onCommandDelete` closure, and returns `nil` — which (per `NSEvent` local-monitor semantics) swallows the event before it reaches either the field editor's own delete-to-line-start handling *or* `PickerView`'s existing `.onKeyPress(.delete)` case, avoiding a double-delete. `AppEnvironment` wires `panel.onCommandDelete = { viewModel?.deleteHighlighted() }` next to the existing `onWillShow`/`onDidHide`. One notable implementation deviation, judged sound on review: the monitor-token property needed `nonisolated(unsafe)` to compile in `deinit` under Swift 6 (a Sendable-safety error, not an actor-hop error — `nonisolated deinit` alone didn't fix it) — mirrors the exact existing precedent at `BlobStore.fileManager`, safe because the property is written exactly once during `@MainActor`-isolated `init` and only ever read in `deinit`.

**Rich previews mechanism.** `ItemRow`'s leading icon slot is now kind-specific: `.image`/`.file` route through a new private `ItemIconThumbnail` (one shared view for both, not two near-duplicates) that loads off the main thread via `Task.detached` + `.task(id:)` (auto-cancels on fast scroll), caches decoded `NSImage`s in a new `ItemThumbnailCache` (`NSCache`, keyed by the content-addressed `blobPath`/`fileReference` — no invalidation logic needed, a cache hit is always correct), and falls back to the pre-existing SF Symbol icon on any failure (missing blob, deleted file, undecodable bytes) — never a crash, never a force-unwrap. `.link` rows get `.foregroundStyle(.accentColor)` + `.underline(true)` applied as an *outer* modifier on the unmodified `HighlightedText` view — deliberately not touching `HighlightedText.swift` itself, since its search-matched ranges already hardcode only `.primary` on the highlighted runs, letting unmatched runs inherit whatever the caller applies externally. Required threading a new `let blobStore: BlobStore` through `PickerViewModel` (extending `AppEnvironment`'s existing single-shared-`BlobStore` rule, first established in D10, to a third consumer) → `PickerView`'s `ItemRow(...)` call site → `ItemRow` → `ItemIconThumbnail`.

**Type-filter chips.** Exactly 5 options in a fixed order (`[nil, .text, .image, .file, .link]`, one `private static let options` constant) — deliberately not `ItemKind.allCases`, which would also surface `.richText`; per this task's literal spec, `.richText` items remain reachable only via "All." Hidden entirely on the Snippets tab (`kindFilter` has no effect there — `SnippetSearchFilter` doesn't consult it), mirroring the pre-existing tab-conditional pattern the "+ New Snippet" button already used.

**Non-text paste.** `PasteContent` (Core) grew `.image(Data)`/`.file(URL)` alongside the original `.text(String)`; `PasteboardWriting` grew a `writeData(_:forType:)` sibling to the existing `writeString(_:forType:)`. `Paster.paste` normalizes `.image` bytes to TIFF via `NSImage(data:)?.tiffRepresentation` before writing under the `.tiff` type (the captured bytes could be either PNG or TIFF depending on what the source app offered — see `PasteboardReader.imagePasteboardTypes` — so this guarantees one consistent format under one pasteboard type rather than a type/bytes mismatch), throwing a new `PasteError.invalidImageData` on undecodable bytes rather than force-unwrapping. `.file` reuses the existing `writeString` with the `.fileURL` type. App-side, `PickerViewModel.select(_:)` now goes through a new `pasteContent(for:)` mapping `ItemKind` → `PasteContent` (`.text`/`.link` → `previewText` verbatim as before; `.image` → bytes read from `BlobStore` via `blobPath`; `.file` → `URL` from `fileReference`; `.richText` → still unsupported, `nil`, unchanged from before this task since its `previewText` remains only a summary, never full content).

**Senior-dev review finding, fixed directly (not re-delegated).** The junior-dev's first pass at `pasteContent(for:)`'s `.image` case used a bare `try? blobStore.read(blobPath:)`, silently swallowing a genuine `BlobStoreError` with zero logging. There *is* existing precedent for silent `try?` in this exact file (`reload()`/`reloadSnippets()`'s `fetchAll` calls) — but those back a self-retrying ~0.4s background poll, where a transient miss is genuinely low-stakes. `pasteContent(for:)` backs a one-shot, non-retrying, direct user action (press Enter / click a row) with **no UI error surface at all** — a real blob-read failure there was a fully silent dead end: no paste, no dismiss, no log, no clue. Rewrote it as `do { return .image(try blobStore.read(...)) } catch { Self.logger.error(...); return nil }`, matching how every other genuine-failure path in this file (`togglePin`, `delete`, `createSnippet`, etc.) already logs metadata-only on a real thrown error. Judged this a small enough, well-scoped fix to make directly rather than spin up a second junior-dev round for one guard clause — re-verified build/lint/tests myself afterward.

**Delegation + verification.** 5 junior-dev sub-tasks (all Sonnet), each reviewed by senior-dev by reading the actual diff (not trusting the summary) plus an independent re-run of build/lint/tests before the next round started. Independently re-validated end-to-end by tester (fresh `xcodegen generate` + `xcodebuild` from scratch, `swift test`, both lint sweeps, plus a static read-and-confirm of every claimed wiring point in all 6 touched/new files against the actual current source) — verdict PASS, zero discrepancies found between what was claimed and what was actually in the files, evidence in `.claude/logs/tester.md`.

**Impact.** `swift test` → 131/131 (128 baseline + 3 new `PasterTests` cases: image-success, invalid-image-throws-before-any-write, file-success). `xcodegen generate` + `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`. `swift format lint --recursive --strict ClipnestApp/Sources` and `Sources Tests` both clean. Report: `.superpowers/sdd/2026-08-06-clipnest-plan/task-rich-content-report.md`.
**Files:** new — `ClipnestApp/Sources/UI/Picker/{ItemThumbnailCache,TypeFilterChips}.swift`; extended — `ClipnestApp/Sources/UI/Picker/{PickerPanel,ItemRow,PickerView,PickerViewModel}.swift`, `ClipnestApp/Sources/App/AppEnvironment.swift`, `Sources/ClipnestCore/Paste/Paster.swift`, `Tests/ClipnestCoreTests/PasterTests.swift`.

**Remaining runtime-only checks (need a human, not exercisable headlessly — same category flagged in every prior UI round, D10 onward):** ⌘⌫ deletes the highlighted row across all three tabs and plain Backspace still edits search text normally; `.image`/`.file` thumbnails actually render (and fall back gracefully on a missing/corrupt blob or deleted file); `.link` rows are visually distinguishable; each chip actually narrows the list, "All" clears it, the selection persists across History↔Pinned but resets on reopen, and chips are hidden on Snippets; selecting an `.image`/`.file` row pastes the real content (not a text summary) into another app; `.text`/`.link` paste is an unregressed baseline check.

### D20 — T44 (routed follow-up): type-filter chips row height reserved on Snippets tab to stop vertical jump on tab switch  (2026-08-10, senior-dev, T44)
Bug: `PickerView.typeFilterChips` used `@ViewBuilder` + `if viewModel.activeTab != .snippets` (D19's original design) to add/remove the whole `TypeFilterChips` row from the top-level `VStack`. Correct for hiding chips that have no effect on Snippets (`SnippetSearchFilter` still doesn't consult `kindFilter` — unchanged), but wrong mechanism: removing a view from a `VStack` also removes its height, so the tab bar/list/footer below it visibly shifted vertically every time the user switched to/from Snippets.

**Fix.** Same row is now unconditionally present (no `@ViewBuilder`/`if`), with tab-conditional `.opacity(0/1)` + `.allowsHitTesting(false/true)` + `.accessibilityHidden(true/false)` instead of conditional presence — the row's frame (padding + `TypeFilterChips`'s intrinsic height) is identical on every tab, so the `VStack`'s total height never changes on tab switch. Chips remain exactly as functional as before on History/Pinned (same binding, same `Button`s); on Snippets they're invisible, don't intercept clicks, and are skipped by VoiceOver — functionally equivalent to being absent, just without the layout side effect. No change to `TypeFilterChips.swift` itself, `tabBar`'s own conditional "+ New Snippet" button (that one's a small trailing element that doesn't change row height either way, so the conditional-removal pattern was never wrong for it), search field, hint footer, or either list.

**Scope.** One file, one property (`PickerView.typeFilterChips`). Delegation: none — PM routed this as a trivial single-file fix with an explicit "do it yourself, don't delegate to juniors" instruction, so senior-dev built it directly rather than spinning a junior-dev round for a one-property change.

**Impact.** `xcodegen generate` + `xcodebuild -project ClipnestApp/ClipnestApp.xcodeproj -scheme ClipnestApp -configuration Debug -derivedDataPath ClipnestApp/DerivedData CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`. `swift test` → 131/131 unchanged (pure App-layer SwiftUI modifier change, zero `ClipnestCore` touched — no new coverage, matching the no-App-test-target precedent already logged in D18/D19). `swift format lint --recursive --strict ClipnestApp/Sources` clean.
**Files:** `ClipnestApp/Sources/UI/Picker/PickerView.swift` (only file changed; `TypeFilterChips.swift` read but not modified — the fix belongs entirely in how the row is composed into the tab-aware layout, not in the chips themselves).
**Remaining runtime-only check (needs a human):** switch History → Snippets → Pinned → Snippets repeatedly and visually confirm the tab bar/list/footer never shift vertically, and that chips on History/Pinned still filter correctly (unaffected by this change, but worth confirming nothing regressed).

### D21 — Type filters relocated into the search-bar row, restyled icon-only; supersedes D20's opacity fix  (2026-08-10, senior-dev, routed UI change)
Routed UI change: move `TypeFilterChips` out of its own standalone row entirely and into the trailing edge of the search field's own row (single header row: search field left/expanding, filters flush right), restyled from text chips to compact icon-only chips. Supersedes D20 — there is no longer a separate filter row for the opacity trick to apply to.

**Design choice — icon-only chips, not a funnel menu.** Went with icon-only chips (task's preferred option) over a compact filter menu: 5 single-glyph 22×22pt buttons fit comfortably at the search row's trailing edge without crowding the text field, and a menu would cost an extra click to see/change the active filter (chips show all 5 states + the active one at a glance, which a collapsed menu button can't). Icons reuse the exact SF Symbols `ItemRow` already draws per kind (`doc.plaintext`/`photo`/`doc`/`link`) via a newly extracted `ItemKind.sfSymbolName` (see DRY note below); "All" gets `square.grid.2x2` (no backing `ItemKind` to source a glyph from, defined once in `TypeFilterChips`). Each chip carries `.help` + `.accessibilityLabel` with the full kind name since an icon alone isn't enough for VoiceOver or a first-time user.

**No vertical jump, by construction not by luck.** `PickerView.header` (new) wraps `searchField` + a conditional `typeFilterChips` in one `HStack`, pinned to a fixed `Self.headerHeight: CGFloat = 40` — not sized from its children. `typeFilterChips` is removed entirely (not merely hidden) on the Snippets tab via a plain `if`, so the search field genuinely gets the full row width there (task's explicit ask), and the fixed height guarantees the row is byte-identical on every tab regardless of which children are actually present — a stronger guarantee than D20's opacity-placeholder trick (which relied on the row always containing the same children) and appropriate now that the children genuinely differ per tab.

**DRY fix taken proactively.** `ItemRow`'s private `iconName(for:)` and the new chip icons needed the identical `ItemKind → SF Symbol` mapping — a real second use appearing at write time, not preemptive — so it's extracted into `ItemKind+SFSymbol.swift` (`ItemKind.sfSymbolName`, ClipnestApp-only extension; `ItemKind` itself stays a zero-UI-dependency `ClipnestCore` value type, per the module-layout rule). `ItemRow.swift`'s duplicate private static func removed; both `.image`/`.file`'s `ItemIconThumbnail` fallback and `.text`/`.richText`/`.link`'s direct icon now read from the one shared mapping.

**Scope.** 4 files: `PickerView.swift` (new `header`, `searchField` loses its own padding, old `typeFilterChips` doc/opacity logic replaced), `TypeFilterChips.swift` (rewritten icon-only), `ItemRow.swift` (icon lookup now delegates to the shared extension), new `ItemKind+SFSymbol.swift`. No `PickerViewModel`/Core changes — `SearchQuery.kindFilter` binding, "All" = no filter, and cross-tab persistence are all unchanged behavior, only the control's location/appearance moved. Delegation: none — PM routed this as small/medium with an explicit "do it yourself" instruction.

**Impact.** `xcodegen generate` + `xcodebuild -project ClipnestApp/ClipnestApp.xcodeproj -scheme ClipnestApp -configuration Debug -derivedDataPath ClipnestApp/DerivedData CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`. `swift test` → 131/131 unchanged (pure App-layer SwiftUI change + one App-only extension file, zero `ClipnestCore` touched — no new coverage needed, matching the no-App-test-target precedent in D18–D20). `swift format lint --recursive --strict ClipnestApp/Sources` clean (one line-length finding in `ItemRow.swift` auto-fixed via `swift format format --in-place`).
**Files:** `ClipnestApp/Sources/UI/Picker/PickerView.swift`, `ClipnestApp/Sources/UI/Picker/TypeFilterChips.swift`, `ClipnestApp/Sources/UI/Picker/ItemRow.swift`, new `ClipnestApp/Sources/UI/Picker/ItemKind+SFSymbol.swift`.
**Remaining runtime-only checks (need a human):** the icon chips actually read clearly at 22×22pt next to the search field and don't look crowded; the active filter's highlight is visually distinguishable; hovering/clicking each icon shows the right tooltip; switching History → Snippets → Pinned → Snippets repeatedly shows zero vertical shift in the tab bar/list/footer (the fixed-height header makes this a stronger guarantee than D20's, but still unverified on an actual screen); the search field visibly reaches full width on Snippets.

### D22 — New reusable `ExpandingIconButton` micro-interaction; applied to the type-filter chips  (2026-08-10, senior-dev, T46 routed follow-up)
Routed UI micro-interaction: build a reusable "expanding icon button" (icon-only at rest, widens on hover to reveal a title sliding in next to the icon, collapses back on hover-out) and apply it to `TypeFilterChips` in place of the plain icon-only `Button` D21 landed.

**New component, new folder.** `ClipnestApp/Sources/UI/Components/ExpandingIconButton.swift` — a generic View (`systemName`, `title`, `isActive: Bool = false`, `action`), no Picker/Settings-specific knowledge. `UI/Components/` is new — coding-standards.md's module layout only lists `UI/Picker/`/`UI/Settings/`; this is the first control shared/sharable across features rather than owned by one screen, so it gets its own shelf rather than living inside `UI/Picker/` (an extension of the documented layout, not a second parallel one — coding-standards.md's file-by-file breakdown should be read as extended by this entry rather than contradicted).

**Mechanism — horizontal-only growth by construction, not luck.** The content `HStack` (icon, then optionally the title) sits inside a frame with an *exact* height (`compactSize = 22`, min == max) and only a *minimum* width (also `compactSize`, no maximum). At rest the icon alone is narrower than `compactSize`, so the frame pads it to a centered square (the "compact square/pill" default look the task asked for). On hover, added horizontal padding + the title `Text` push the ideal content width past `compactSize`; since width has no ceiling the frame just grows to fit exactly — no slack — which places the icon at the leading edge and the title at the trailing edge of the now-wider button. That reflow is what reads as "icon slides left, title slides in from the right" — ordinary SwiftUI layout, not a manual offset/GeometryReader animation. One `withAnimation(.easeInOut(duration: 0.2))` per hover-state change (in `.onHover`, not a bare `.animation(value:)` modifier — more reliable for driving both the frame/padding change and the title's `.transition(.opacity.combined(with: .move(edge: .trailing)))` together) animates the whole reflow. Height being pinned exactly (not just a minimum) is what guarantees the control can never grow vertically regardless of caller/font metrics — the task's one hard constraint (header row height must stay locked at 40pt). `isHovering` is private per-instance `@State`, the same pattern `RowActionButton` already uses, so only the actually-hovered button expands; siblings are unaffected.

**Applied to `TypeFilterChips`.** `chip(for:)` now returns one `ExpandingIconButton(systemName:title:isActive:action:)` per option instead of building its own `Button`+background+`.help`+`.accessibilityLabel` — those last two now live in `ExpandingIconButton` itself (removed from `TypeFilterChips` to avoid duplicating them). Zero behavior change: `SearchQuery.kindFilter` binding, "All" = no filter, cross-tab persistence, and the chips' trailing-right position in the search row (T45/D21) are all untouched — only how each chip renders changed.

**Reuse noted, not acted on.** Built generic enough to reuse for `ItemRow`/`SnippetRow`'s `RowActionButton` (pin/save-as-snippet/delete/edit) later — flagged in the component's own doc comment — but that swap is explicitly out of scope for this task: those buttons sit in an already 2–3-wide trailing row where multiple buttons expanding simultaneously needs its own layout pass (would neighbors also need to shift, does an expanded button's title get clipped by the row's fixed trailing edge, etc.) that this task doesn't investigate or assume answers for.

**Impact.** `xcodegen generate` + `xcodebuild -project ClipnestApp/ClipnestApp.xcodeproj -scheme ClipnestApp -configuration Debug -derivedDataPath ClipnestApp/DerivedData CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`. `swift test` → 131/131 unchanged (App-layer-only SwiftUI addition, zero `ClipnestCore` touched — no App test target exists, matches D18–D21 precedent, flagged not silently skipped). `swift format lint --recursive --strict ClipnestApp/Sources` clean.
**Files:** new `ClipnestApp/Sources/UI/Components/ExpandingIconButton.swift`; `ClipnestApp/Sources/UI/Picker/TypeFilterChips.swift` (chip rendering delegated to the new component).
**Remaining runtime-only checks (need a human, same category as D19–D21):** the hover expand/collapse motion is actually smooth at ~0.2s with the described easeInOut feel; the icon visibly slides left and the title visibly slides in from the right (not just "appears"); only the hovered chip expands, neighbors unaffected; nothing clips/overflows or wraps to a second line at the picker's ~560pt width with a chip expanded; the header row's height genuinely never jumps on hover.

### D23 — T47 (routed bug report): picker search hang, root-caused via benchmark — unbounded `previewText` + uncached, synchronous, main-thread filtering  (2026-08-10, senior-dev, T47)
User-reported: "the application hangs terribly while searching... keep this lightweight and fast, no lag." Root-caused before touching any code, not guessed — see the mechanism below and the actual benchmark numbers.

**Root cause, confirmed by benchmark.** `PickerViewModel.items` (History/Pinned's filtered list) was four chained, **uncached** computed properties: `filteredItems` (`SearchFilter.filter(allItems, matching: query)`) → `pinnedRun`/`unpinnedRun` (partition + sort) → `items` (switch on `activeTab`). Every one of these re-ran from scratch on every single *read* — no memoization — and `PickerView`'s body reads `viewModel.items` 2-3 times per render (the empty-state check, `ScrollResettingList`'s `data:` argument, plus `selectFirstResult()`'s own read fired synchronously from `query`'s `didSet` on every keystroke). So one keystroke triggered 2-3 full O(n) scans of `allItems`, run synchronously on `@MainActor` during SwiftUI's view-body evaluation — which blocks the run loop, and therefore blocks the *next* keystroke, until they finish. The specific thing that turned "slow" into "hangs terribly": `ClipItem.previewText` has **no length cap** — `PasteboardReader.readPlainText` stores the full trimmed text verbatim for `.text`/`.link` items, because `previewText` is deliberately overloaded to also be the *full content* used for paste-back (`PickerViewModel.pasteContent(for:)`), not just a display preview — so a single realistic large paste (a copied source file, log, or long doc — an easy, common power-user action, not a contrived edge case) sits in `allItems` at full size, uncapped, forever (or until deleted / a retention cap trims it — off by default, see T32). A throwaway benchmark (`localizedCaseInsensitiveContains` over 2000 ~80-char items + 5 ~2MB items, simulating one big paste) measured a single filter pass jumping from ~2ms (no big items) to **26-72ms** (with them) — and the old design paid that cost 2-3x per keystroke, with zero debounce, exactly matching the reported symptom.

**Fix — `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift` only, no schema change.** Collapsed the four computed properties into one `@Published private(set) var items: [ClipItem]`, recomputed by a new `scheduleFilterUpdate(_ policy: SelectionPolicy, debounced: Bool)`:
- The actual filter+partition+sort pass (`Self.filteredAndSorted(...)`, a new `nonisolated static func` — carries no actor isolation, safe off `@MainActor`) now runs inside a `Task.detached(priority: .userInitiated)`, never inline during a SwiftUI render or a synchronous property read. Only the final `self.items = result` + selection update happen back on `@MainActor`, via one `MainActor.run` hop.
- A ~120ms debounce (`Duration.milliseconds(120)`) is applied **only** to the search-text-typing path (`query`'s `didSet`) — short enough to still read as instant typing, long enough to coalesce a fast typist's keystrokes into one filter pass instead of one per character. Tab switches (`activeTab`'s `didSet`), the live-refresh poll, and post-mutation reloads (pin/delete/snippet CRUD) all pass `debounced: false` and resolve on the very next run-loop turn — unchanged, still instant, exactly as before this fix. Debouncing those would add perceptible lag to actions that were never the actual bottleneck.
- `filterTask` is a single shared, cancellable property — a new call always cancels whatever's pending (mid-debounce-sleep or mid-filter) before starting fresh, and every suspension point re-checks `Task.isCancelled` before touching `@MainActor` state, so "latest request wins" holds regardless of how calls interleave (traced by hand: `willShow()`'s debounced reset racing `startLiveRefresh()`'s immediate reload on picker-open; a keystroke landing while a delete's `reload(selectingIndexNear:)` is still in flight) — no stale-overwrite path found in any traced interleaving.
- A new `SelectionPolicy` enum (`.hardReset` / `.softReconcile` / `.selectNear(previousIndex:)`) replaces what used to be three separate inline selection-update call sites (`query`'s `didSet`, `reload(resetSelection:)`, `reload(selectingIndexNear:)`), applied once inside `scheduleFilterUpdate` after the fresh result lands, instead of each call site reading `items` (now momentarily-stale-until-the-recompute-lands) directly.

**Near-zero blast radius on the rest of the file.** `selectFirstResult()`, `reconcileSelection()`, `highlightedItem`, `highlightedSnippet`, `moveSelection(by:)`, `togglePinHighlighted()`, `saveHighlightedAsSnippet()`, `deleteHighlighted()` all needed **zero changes** — every one of them only ever *reads* `items`, and a stored `@Published private(set)` property satisfies that identically to how the old computed one did (the fix is entirely about *when*/*where* `items` gets computed, not what reads it). Only `query`'s/`activeTab`'s `didSet`s and the two `private func reload(...)` overloads changed their call sites.

**Deliberately not fixed — flagged as a follow-up, not done unilaterally.** A second, compounding cause was found while root-causing but left alone: `ClipStore.fetchAll(matching:)` (both `SwiftDataClipStore` and the `ClipStore` protocol) has **no result cap** — every ~0.4s live-refresh poll re-fetches the *entire* history table, full `previewText` included, off `@MainActor` but still a real, unbounded, growing cost since T32's retention cap defaults off. Capping `fetchAll` (or defaulting the retention cap on) changes *product* behavior — how far back History can search/scroll — not a pure performance bugfix, so it wasn't changed here; flagged for architect/PM as a related follow-up (ties into T28/T30's not-yet-wired Settings UI for the retention cap).

**Verification.** `xcodegen generate` + `xcodebuild -project ClipnestApp/ClipnestApp.xcodeproj -scheme ClipnestApp -configuration Debug -derivedDataPath ClipnestApp/DerivedData CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **` (compiled clean under Swift 6 strict concurrency on the first attempt — `ClipItem`/`SearchQuery`/`PickerTab`/`SearchFilter` are all `Sendable`, so the `Task.detached` closure's captures needed no extra plumbing). `swift test` → 131/131 unchanged (App-layer-only change, zero `ClipnestCore` touched). `swift format lint --recursive --strict ClipnestApp/Sources Sources Tests` clean. No App-level test target exists for this file (established precedent — D18–D22, T43's identical "AppKit/Combine timing logic, no automated coverage possible, verified via build + manual trace" call) — verified instead by the standalone benchmark (proves the mechanism) plus a full hand-trace of every call site and interleaving (proves no regression), not a unit test; flagged, not silently skipped.
**Files:** `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift` (only file changed).
**Remaining runtime-only checks (need a human — the benchmark proves the mechanism, not the on-screen feel):** typing in the search field genuinely feels instant/lag-free now, especially once a large item (a big paste) is in History; the highlighted/selected row stays correct through rapid typing, tab switches, and a delete that happens mid-search; no regression in the picker's existing keyboard-driven UX (Return/↑/↓/⌘P/⌘S/⌘⌫) since `highlightedItem` and friends were untouched but now read a push-updated rather than pull-computed `items`.

### D24 — T48: `ExpandingIconButton` extended to the row action buttons (pin/save/delete, edit/delete), replacing `RowActionButton`  (2026-08-10, senior-dev, T48)
Direct follow-up to T46/D22: user asked to "apply the same button design to the pin, save and delete buttons as well" — extend the hover-expand micro-interaction from the type-filter chips to `ItemRow`'s and `SnippetRow`'s trailing row actions.

**What changed.** All 5 remaining call sites of the old `RowActionButton` (`ItemRow.rowActions`: pin/unpin, save-as-snippet, delete; `SnippetRow.rowActions`: edit, delete) now use `ExpandingIconButton`, reused **as-is** — no new parameters were added to the shared component for this. `RowActionButton` itself is deleted (`ItemRow.swift`, its only other caller `SnippetRow.swift` migrated in the same pass) — one shared icon-button component now, not two overlapping ones, per coding-standards.md's DRY/consistency rule.

**Design call: `isActive` stays `false` for every row action.** `ExpandingIconButton.isActive` drives a semantic "selected among alternatives" tint + background fill (built for the type-filter chips, where exactly one of five is the active filter). None of pin/save/edit/delete is that kind of control — there's no mutually-exclusive selection among them. Pinned state (`item.pinned`) keeps communicating itself exactly the way it did before this change: the icon glyph (`pin` vs `pin.fill`) plus the dynamic title ("Pin" vs "Unpin"), never through `isActive`'s tint/background. Considered and rejected: giving the row buttons their own resting/hovered color knobs on `ExpandingIconButton` to preserve the old `RowActionButton`'s exact grey-scale-no-background look — decided against adding component-level styling knobs for a difference this small; the component's existing `.secondary` resting foreground plus its subtle hover background fill reads as an *improvement* over the old design's only-a-brightness-change hover feedback (the title reveal itself is now the primary, unambiguous "this is interactive" signal), and keeping one consistent look for every icon-only control in the picker (header chips + row actions) is a deliberate small unification rather than an accidental one.

**Multi-button-per-row correctness, confirmed not just assumed.** `ItemRow` can show up to 3 `ExpandingIconButton`s side by side. `isHovering` was already private, per-instance `@State` in `ExpandingIconButton` (T46's design) — verified this still holds with 2-3 instances in one `HStack`: each tracks its own hover state independently, so only the button actually under the cursor ever expands; no shared/coordinated state was needed. The row's own leading content (a `Spacer`-pushed, `.lineLimit(1)`/`.truncationMode(.tail)` text block) absorbs an expanding button's extra width the same way `PickerView.header`'s search field already does for the type-filter chips (same underlying SwiftUI layout mechanism, no new code needed for it).

**Row height.** `ExpandingIconButton` pins its own height to an exact 22pt (T46's design, unchanged here). `ItemRow`'s two-line text block (title + relative-timestamp caption) is taller than 22pt and already determines the row's overall height, so swapping the trailing buttons' sizing shouldn't visibly change row height — reasoned through, not measured on a real screen, so still flagged as a runtime-only check below.

**Impact.** `xcodegen generate` + `xcodebuild -project ClipnestApp/ClipnestApp.xcodeproj -scheme ClipnestApp -configuration Debug -derivedDataPath ClipnestApp/DerivedData CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`. `swift test` → 131/131 unchanged (App-layer-only change, zero `ClipnestCore` touched). `swift format lint --recursive --strict ClipnestApp/Sources` clean.
**Files:** `ClipnestApp/Sources/UI/Picker/ItemRow.swift` (`RowActionButton` struct deleted, `rowActions` migrated), `ClipnestApp/Sources/UI/Picker/SnippetRow.swift` (`rowActions` migrated), `ClipnestApp/Sources/UI/Components/ExpandingIconButton.swift` (doc comments updated to reflect the completed reuse — no behavior change to the component itself).
**Remaining runtime-only checks (need a human):** hover-expand on pin/save/delete/edit feels smooth and reads clearly at row width; no clipping/wrapping in the row's text block when a button expands; multiple buttons in the same row don't visually collide with each other when one expands near another; row height is genuinely unchanged from before this task.

### D25 — T47 review-fix round: closed the stale-commit-action race + non-search async-flash gaps reviewer found in D23's search-perf fix  (2026-08-10, senior-dev, T47)
Independent reviewer pass on D23 (`.superpowers/sdd/2026-08-06-clipnest-plan/perf-review.md`) found 2 Important + 2 Minor + 1 Nit, all in the debounce/scheduling design, not the underlying filter logic. Fixed all 5, same one file, no other scope.

**Important #1 (blocking) — commit actions could act on a stale row.** `highlightedItem`/`selectedItemID` only updated once the debounced `filterTask` landed, up to ~120ms after the last keystroke — so Return (paste)/⌘P (pin)/⌘S (save-as-snippet)/⌘⌫ (delete) fired inside that window could act on the row highlighted *before* the user's last keystroke(s), not the row matching what they'd just typed. Real hazard for a clipboard manager: wrong-paste (possibly of a more sensitive prior item) or wrong-delete, no undo visible in this file. **Fix:** new `flushPendingFilter()` — if `filterTask` is non-nil (a debounced search update is genuinely pending), cancels it and calls the new `applyFilterSynchronously(.hardReset)` to recompute `items`/selection from the *current* `allItems`/`query`/`activeTab` right there, synchronously, on `@MainActor`. Called at the top of `selectHighlighted()`, `togglePinHighlighted()`, `saveHighlightedAsSnippet()`, `deleteHighlighted()` — the four entry points that read `highlightedItem`. Correctness argument: `query`'s `didSet` is the only call site that ever passes `debounced: true` (grepped, unchanged by this fix), so a pending `filterTask` always corresponds to policy `.hardReset` — flushing with `.hardReset` is exactly what that pending update would itself have applied, just done now instead of up to 120ms later.

**Important #2 — non-search updates were still async, could flash stale `items`.** The original fix's `scheduleFilterUpdate` routed *every* call (`debounced: true` or `false`) through `Task.detached` + `await MainActor.run` — so even "not debounced" paths (tab switch, ~0.4s live-refresh poll, post-mutation reload) had an unavoidable async gap where SwiftUI could render the new tab/state over the *previous* `items`, undoing part of the point of D23's own benchmark (30-70ms filter passes aren't always sub-frame). **Fix:** `scheduleFilterUpdate(_:debounced:)` now branches — `debounced: false` calls the new `applyFilterSynchronously(_:)` directly, inline, on `@MainActor`, no `Task.detached` at all. Only `debounced: true` (search-text typing, the one rapid-fire case that motivated moving work off-thread in the first place) still debounces+detaches. Extracted the selection-policy switch into a shared `applySelectionPolicy(_:result:)` so the sync and async paths apply `.hardReset`/`.softReconcile`/`.selectNear` identically instead of duplicating the switch.

**Minor #1 — `filterTask` not nil'd on cancel.** Now nil'd in three places: `didHide()` (mirrors `stopLiveRefresh()`'s `refreshTask` pattern), unconditionally at the top of `scheduleFilterUpdate` before branching, and inside the debounced closure's `MainActor.run` block once it lands (relies on the same "only one non-cancelled task can exist at a time" invariant the original review verified for latest-request-wins — a cancelled task never reaches that line, so it's always safe to nil there).

**Minor #2 (Snippets' `snippets` computed property) — deliberately NOT touched**, per the reviewer's own explicit "leave it for now, out of scope" note.

**Nit — `query`'s `didSet` missing an equality guard.** Added `guard oldValue != query else { return }`, mirroring `activeTab`'s existing guard. `SearchQuery` was already `Equatable` (`Sources/ClipnestCore/Search/SearchQuery.swift`) — no new conformance needed.

**Verification.** `xcodegen generate` + clean `xcodebuild -project ClipnestApp/ClipnestApp.xcodeproj -scheme ClipnestApp -configuration Debug -derivedDataPath ClipnestApp/DerivedData CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`; grepped the full clean-build log for `PickerViewModel` — zero warnings/errors. `swift test` → 131/131 unchanged. `swift format lint --recursive --strict ClipnestApp/Sources` and `Sources Tests` both clean. Hand-traced: rapid-typing-then-instant-commit now flushes to the current query before acting; tab switch/poll/reload compute synchronously (no flash window); `filterTask` never left pointing at a finished/cancelled task in any traced path; latest-request-wins for the typing path is unchanged (same cancel-then-replace + `Task.isCancelled` re-check protocol as D23).
**Files:** `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift` (only file changed — confirmed via `git diff --stat`).

### D26 — Phase E (T35-T37): release scripts built + fully validated except the two genuinely account-gated steps (real Developer ID sign, real notarytool submit)  (2026-08-10, devops, T35/T36/T37)
New `scripts/` directory: `build.sh` (T35), `sign.sh` + `notarize.sh` (T36, + `ClipnestApp/project.yml` Release signing settings), `package_dmg.sh` (T37, + README "Release" section). All four `shellcheck`-clean, `bash -n`-clean, chained and run end-to-end for real in this sandbox as far as the environment allows — see devops's `T35-T37` log entry for the full evidence.

**build.sh — always runnable without a signing identity, by design.** Archives with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` unconditionally (same pattern this whole session's ad-hoc dev builds already used for `xcodebuild ... build`, now extended to the `archive` action too — that extension is a deliberate, logged choice, not an oversight). Export step branches on whether `$DEVELOPMENT_TEAM` is set: unset → direct copy of `Products/Applications/Clipnest.app` out of the archive (today's real path, verified — produces a genuine, launchable universal `Clipnest.app`); set → generates `build/ExportOptions.plist` (method `developer-id`, `teamID` from the env var, never written to a tracked file) and runs `xcodebuild -exportArchive`. Tested both branches for real: the unset path succeeds end-to-end; the set path (with a fake team ID, no real cert installed) correctly reaches Apple's own `xcodebuild` export logic and fails loudly with `No signing certificate "Developer ID Application" found` rather than silently producing a partial/wrong artifact — exactly the fail-loud behavior required, and real evidence the plist-generation + export invocation are wired correctly.

**project.yml — DEVELOPMENT_TEAM/CODE_SIGN_IDENTITY parameterized via XcodeGen's `${VAR}` expansion, Release config only.** Confirmed via deepwiki (yonaskolb/XcodeGen) that `${VAR}` is expanded from the shell environment at `xcodegen generate` time and resolves to an empty string if unset (never an error, never a literal placeholder left in the generated project) — verified live by generating with a fake `DEVELOPMENT_TEAM` set and confirming it flowed through to the archive's signing settings. Debug config is untouched (no signing settings added there) so local dev builds are unaffected.

**sign.sh / notarize.sh — identity and keychain-profile name are the only two "credentials," and both are argument/env-var only, never literal.** Grepped the diff explicitly (see log) — zero matches beyond the header comments' own `<placeholder>` documentation examples. `notarize.sh`'s header documents the one-time, out-of-band `xcrun notarytool store-credentials` setup the Apple-Developer-account owner must run themselves (per this file's existing Phase E constraint) — this script never touches an Apple ID/password/API key itself, only the profile *name*.

**notarize.sh uses `ditto -c -k --keepParent`, not plain `zip`** — Apple's own recommended way to zip a `.app` for notarization submission (preserves the codesign resource fork/xattrs `zip` can silently corrupt). Verified for real: ran against the actual ad-hoc-signed `build/Clipnest.app`, the zip was produced correctly (`Clipnest.app/` at the archive root, `_CodeSignature` intact), and `xcrun notarytool submit ... --keychain-profile "clipnest-release-profile" --wait` was genuinely invoked and failed with Apple's own real error (`No Keychain password item found for profile: clipnest-release-profile`) — proof the submit command and its flags are correct, not just that the script parses.

**package_dmg.sh — installed `create-dmg` (`brew install create-dmg`) rather than only building the hdiutil fallback**, since the task left it as a judgment call and installing it let both branches be validated for real rather than one being untested logic. Both branches produce the identical, correct drag-to-Applications layout (`Clipnest.app` + an `Applications -> /Applications` symlink at the DMG root — confirmed by mounting and listing both outputs). One real fix needed: `create-dmg`'s Finder-"prettifying" AppleScript step hung indefinitely in this non-interactive agent shell (no way to grant the Automation permission it needs to control Finder) — added `--skip-jenkins` (create-dmg's own documented flag for "Sandbox and non-GUI environments") to skip only that cosmetic step; the DMG's actual structure (app + Applications symlink) is unaffected, confirmed by inspection. Anyone running this from an interactive Terminal with Automation permission already granted still gets the same window-position/icon-layout options passed — `--skip-jenkins` just prevents a hang when that permission isn't available, it doesn't remove the option.

**Genuinely account-gated, not run to real completion (stated explicitly, not glossed over):** a real Developer-ID `codesign` (only ad-hoc `-` was available — proves the exact same `codesign --deep --force --options runtime --sign` invocation, `--verify`, and `spctl --assess` output structure/flags, but isn't a real Developer ID signature) and a real `notarytool submit --wait` (no Apple Developer account/keychain profile exists in this sandbox — this is the same pre-existing external dependency this file already calls out for M9/T35-T39, not a new gap). Both scripts are correct and ready; the account owner runs the actual sign+notarize themselves per `notarize.sh`'s header instructions.
**Files:** `scripts/build.sh`, `scripts/sign.sh`, `scripts/notarize.sh`, `scripts/package_dmg.sh` (new), `ClipnestApp/project.yml` (extended, Release config only), `README.md` (Install framing + new "Release" section), `.gitignore` (added `build/` — the pipeline's own generated output, never meant to be committed; not in the task's originally-listed file scope but a necessary, minimal, logged companion change to keep the repo reproducible/artifact-free).
**Remaining runtime-only checks (need a human, in addition to D23's list):** type then immediately hit Return/⌘⌫ — confirm it acts on the just-typed-for row, not a leftover one; switch tabs with a large paste in History — confirm no visible flash of the previous tab's rows.

### D27 — Phase E wrap-up: reviewer + tester cleared T35-T38 for `done`; T39 stays `blocked` on Phase D, a real board-vs-source-tree gap found and partly closed  (2026-08-10, senior-dev, T35-T39 + board audit)
User asked to "wind this up, create docs, build, release pipelines." Closed the loop on Phase E (already built/self-reviewed as D26) with the two remaining independent gates, wrote the senior-dev docs slice, and surfaced a real project-tracking gap while doing so — recorded together since they were found and resolved in the same pass.

**Reviewer (T38) — APPROVE.** Independent mandatory security pass (integrity rule 3 hard trigger — scripts touch credentials/external I/O) came back clear: no hardcoded credentials anywhere (grepped for Team-ID/Apple-ID/password/API-key/app-specific-password shapes across every touched file — zero real hits, only doc placeholders), identity/profile always arg-or-env with fail-loud on empty, `ClipnestApp.entitlements` untouched, `.gitignore build/` verified via `git check-ignore` to actually cover the one file that would embed a Team ID (`build/ExportOptions.plist`) plus every signed artifact, and the only network I/O (`notarytool submit --wait`) is explicit and user-initiated. Correctness pass clean too (shellcheck, chain composition, matches plan verbatim). Two non-blocking nits noted (spec-mandated `codesign --deep`, minor export/sign redundancy) — neither changed anything.

**Tester (T39) — PASS for everything Phase-E-scoped and exercisable in this sandbox.** Independently re-ran the full chain from a clean `rm -rf build/` state with real pasted output: `swift test` 131/131, `build.sh`→`sign.sh "-"`→`package_dmg.sh` all real and green, the resulting `build/Clipnest.dmg` mounted and confirmed structurally correct (`Clipnest.app` + `Applications -> /Applications` symlink), `notarize.sh`'s no-argument failure path and its signature-check-before-submit guard both confirmed, shellcheck clean, and — going further than the review pass — actually launched `build/Clipnest.app` for real and confirmed it ran 5+ minutes with zero crash-log entries before quitting cleanly (the menu bar icon glyph itself couldn't be visually confirmed — no display/console access in this sandbox, same category as D10/D13/D14, not a new gap). Also confirmed the Release-only `project.yml` change didn't regress the everyday Debug build devs actually use. **Verdict: T35/T36/T37/T38 → `done`.**

**T39 itself stays `blocked`, deliberately not `done`.** T39's own literal AC is "only after this does the overall Clipnest v1 scope count as done," and it formally depends on T34 (Phase D tester validation). Phase D (T28 Settings window, T29 menu-bar quick menu, T30 excluded-apps wired to real settings, T31 pause-capture UI, T33 reviewer, T34 tester) is genuinely unbuilt — confirmed by spot-check, not assumed: no Settings UI folder exists anywhere in `ClipnestApp/Sources/UI`, and `ClipboardMonitor.excludedBundleIDsProvider` still defaults to an empty closure with nothing supplying real user-configured exclusions. Neither senior-dev nor tester attempted to build or paper over Phase D this turn — explicitly out of scope for this task, and a large enough body of work (a whole Settings window + several wiring points) that it needs its own plan, not something to silently absorb into a "wind up the release pipeline" ask.

**Real board-vs-source-tree discrepancy found and partly fixed.** While auditing ahead of T39 (to know what "full regression" honestly meant), found that `.claude/task-board.md`'s T27 (HotkeyManager) showed `status:todo` despite being fully built and wired — real `ClipnestApp/Sources/System/HotkeyManager.swift` (real `KeyboardShortcuts` dependency, `⌥⌘V` default per D11), called from `AppEnvironment.swift:178`. The file's own doc comment references a prior "fix-round-2 report," confirming this was actually built and iterated on in an earlier pass whose board update never landed — a bookkeeping gap, not missing code. Fixed that one entry with evidence (now `review`, not `test`, since the actual hotkey registration is a real-run-only check per its own doc comment, not independently re-verified this turn). Did **not** exhaustively re-audit every other task — spot-checked T28-T31/T33/T34 and confirmed those genuinely match their `todo` status (see Phase D paragraph above). Separately, also found `.claude/task-board.md`'s T47 entry (the search-hang fix, D23) had never been updated after an independent reviewer pass (`.superpowers/sdd/2026-08-06-clipnest-plan/perf-review.md`) found and a fix round closed 2 Important + 2 Minor + 1 Nit gaps in D23's debounce/scheduling design (most notably a real stale-commit-action race — recorded as D25, already in this file, dated the same day) — fixed that board entry too, bumping T47 to `test` with the D25 evidence summarized in place.

**Docs — senior-dev's slice.** New `docs/API.md`: the full `ClipnestCore` public API reference (every public type/protocol/function/error across Model/Store/Clipboard/Search/Paste, organized by module, with a working end-to-end capture→search→paste example). Verified the example for actual Swift correctness before calling it done, not just plausibility — caught and fixed a nested-`try` ambiguity and a missing `import AppKit` on my own re-read. Cross-linked from `README.md`'s "How it's built" section so it's actually discoverable rather than orphaned (a minimal, one-paragraph addition — didn't touch any of devops's Release-section prose or rewrite unrelated parts of the README). Architect's overview/getting-started slice and tester's verified-how-to slice are both still open — not written here, per the three-way doc split this project already uses (see `.claude/instructions.md`'s "User-facing docs" section) — flagged, not silently claimed.

**Impact.** `swift test` → 131/131 (tester's fresh run, T39). Full script chain real and green (T39). `docs/API.md` new. `.claude/task-board.md`: T35/T36/T37/T38 → `done`; T39 → `blocked` (Phase D dependency, stated explicitly); T27 → `review` (board-sync fix); T47 → `test` (board-sync fix for the already-completed D25 round).
**Files:** `docs/API.md` (new), `README.md` (one-paragraph cross-link addition), `.claude/task-board.md` (T27/T35-T39/T47 entries), `.claude/logs/senior-dev.md`.
**Follow-up recommended, not actioned here:** route a Phase D scope/plan task to PM/architect — the Settings window + quick menu + excluded-apps wiring + pause-capture UI is genuinely unbuilt and is what's actually standing between this project and a true "v1 done," not anything in Phase E.

### D28 — T53: SwiftData additive-non-optional-attribute rule — new `@Model` required attributes MUST ship with a default value, or they crash launch against every existing on-disk store  (2026-08-11, senior-dev, T53, critical launch-crash fix)
T49/T50's DB-virtualization change (D-none-recorded — see `db-virtualization-report.md`) added `normalizedText: String` to both private `@Model` records (`ClipItemRecord`, `SnippetRecord`) as a plain non-optional stored property with no default. That's the one case D14's own migration note didn't cover: D14 established that a purely *additive optional* field (`pinnedAt: Date?`) needs no `VersionedSchema`/migration plan — true, and still true — but a *non-optional* additive field is a different, stricter case SwiftData's lightweight migration handles very differently. Confirmed from a real runtime crash log against the user's actual, intact 3.8MB on-disk store: `NSCocoaErrorDomain 134110`, "Cannot migrate store in-place: Validation error missing attribute values on mandatory destination attribute." `ModelContainer` construction threw on every launch → `AppEnvironment.init` propagated it → `AppDelegate` terminated the app before the hotkey/menu bar ever registered — from the user's side this looked exactly like "the global shortcut stopped working," with no further symptom, because the app never got past launch.

**The rule going forward (binding on all future `@Model` schema changes to `ClipItemRecord`/`SnippetRecord`, not just this one field):** adding a new attribute to either record is safe under SwiftData's automatic lightweight migration **only if** it's either (a) `Optional` (defaults to `nil` on existing rows — D14's case, still fine, no change needed), **or** (b) non-optional *with an explicit Swift default value expression* (`= ""`, `= 0`, `= false`, etc. — mirrors Core Data's own lightweight-migration rule that a new required attribute must be optional or defaulted). A non-optional attribute with **no** default is the one combination that always breaks migration of an existing store — exactly what happened here. Any future PR/task adding a stored property to either private `@Model` record must satisfy (a) or (b); reviewer should treat a bare non-optional addition with no default as an automatic blocker on any future review of these two files, not just a style nit.

**Fix applied (both records).** `normalizedText: String` → `normalizedText: String = ""` in both `ClipItemRecord` (`SwiftDataClipStore.swift`) and `SnippetRecord` (`SwiftDataSnippetStore.swift`). This alone restores migration (rule (b) above) — it does **not** by itself make old rows searchable again, since every migrated-in row gets `normalizedText == ""` (the default), not the real derived value. So both stores' `init` also gained a one-time best-effort backfill (`backfillNormalizedText(in:)`, private static, runs against the freshly-built `ModelContext` before `self.modelContext`/`self.blobStore` are assigned): finds rows where `normalizedText == ""` and the source text isn't, recomputes it with the exact same derivation live inserts/updates already use, saves once. Runs on every `init` (cheap after the first launch — the predicate matches nothing once everything's backfilled), and is deliberately non-throwing (logs metadata-only on failure, per coding-standards.md, and swallows) — a backfill hiccup must never become a second version of the exact "app won't launch" bug this fix exists to close.

**Testing note for future SwiftData migration bugs.** Proving "the default makes migration safe" (not just "the backfill logic works once data is already shaped correctly") required a genuine two-schema-version test — a store file written under the literal pre-fix shape (no `normalizedText` at all), then reopened with the current schema. Achieved without `VersionedSchema` machinery by declaring a test-local `@Model` type with the *same simple type name* as the production record (`ClipItemRecord`/`SnippetRecord`) but the old shape — SwiftData names a Core Data entity after the type's simple name (not the module), so this genuinely drives Core Data's real lightweight-migration path. **Caveat for reuse:** doing this is not free — two structurally different, same-named `@Model` types being resolved *concurrently* by Core Data's schema machinery is not thread-safe; it nondeterministically corrupted unrelated sibling tests under Swift Testing's default parallel execution until the affected suites (`SwiftDataClipStoreTests`, `SwiftDataSnippetStoreTests`) were marked `@Suite(..., .serialized)`. Any future test using this same-name-shadow technique must live in a `.serialized` suite.

**Impact.** `swift test` → 164/164 (160 baseline + 4 new). `swift build` clean. Both lint sweeps clean. `xcodebuild` (Debug, App target) → `** BUILD SUCCEEDED **`. App not launched this session (explicit instruction) — the controller relaunches against the real existing store next to confirm the crash is actually gone in practice, not just proven by test.
**Files:** `Sources/ClipnestCore/Store/SwiftDataClipStore.swift`, `Sources/ClipnestCore/Store/SwiftDataSnippetStore.swift`, `Tests/ClipnestCoreTests/SwiftDataClipStoreTests.swift`, `Tests/ClipnestCoreTests/SwiftDataSnippetStoreTests.swift`. Report: `.superpowers/sdd/2026-08-06-clipnest-plan/migration-fix-report.md`.

### D29 — T54: async-selection-vs-`List(selection:)` is a first-responder race, not just this one bug — any future `PickerViewModel` code path that (re)writes `selectedItemID`/`selectedSnippetID` after an `await` must re-bump `focusToken`  (2026-08-11, senior-dev, T54, critical UX fix)
Tester's own adversarial critique (`search-input-critique.md`, code-analysis only) root-caused the reported "picker search box registers zero typed characters" bug: T50/T51's DB-virtualization rewrite (D-none-recorded, see `db-virtualization-report.md`) made every row/snippet query a real async `ClipStore.query`/`SnippetStore.query` round-trip, so `rows`/`snippetRows` and their selection now settle *after* an `await` on every path (open, debounced search, tab/kind-filter switch, live capture, post-mutation refresh) — there is no synchronous path left, per that file's own top doc comment. Writing a macOS SwiftUI `List`'s `selection` binding *programmatically* makes the underlying `NSTableView` claim first-responder status inside `PickerPanel` as a side effect (confirmed: this is standard AppKit/SwiftUI interop behavior, not Clipnest-specific), and since that write now lands after the `await`, it lands *after* the search field's own synchronous `.focused()` request instead of before it — silently stealing keyboard focus, repeatedly (on open, and again ~400ms after every keystroke via the debounced reload).

**The rule going forward (binding on any future `PickerViewModel` change that touches `rows`/`snippetRows`/`selectedItemID`/`selectedSnippetID`):** any code path that (re)writes the row/snippet selection **after an `await`** must re-bump `focusToken` immediately after that write, so the search field's focus claim is always the *last* one applied for that render pass — never rely on synchronous ordering against `List(selection:)`, since T50/T51 already proved that ordering doesn't hold once a store round-trip is in the mix. Reviewer should treat any new async selection-write path that skips this as an automatic blocker, the same way D28's SwiftData-default rule is now a standing review check.

**Fix applied.** Bumped `focusToken` (via a new shared private `reassertSearchFieldFocus()`) at the tail of both `applyRowsSelectionPolicy(_:result:)` and `applySnippetsSelectionPolicy(_:result:)` in `PickerViewModel.swift` — the two methods every async selection-write path already funnels through (first-page requery *and* post-mutation window refresh, both tabs), so this closes the race for every current trigger without touching `PickerView.swift` (its `.onChange(of: viewModel.focusToken)` observation was already correct — confirmed by read, nothing there needed to change) or duplicating the bump at each of the 4+ call sites individually. `refocusSearchField()` (pre-existing, called by `AppEnvironment` on `SnippetEditorWindow` close) now delegates to the same helper instead of its own duplicate `focusToken += 1`.

**Why this can't trap focus on a genuine user action, reasoned through explicitly (not just asserted):** a manual row click and `moveSelection(by:)` (arrow keys) both write `selectedItemID`/`selectedSnippetID` **directly**, never through `apply*SelectionPolicy` — so the new bump never fires for either, and can't override a selection the user made on purpose. `SnippetEditorWindow` is a separate real `NSWindow` (not a subview of `PickerPanel`), confirmed by read — `focusToken` only re-asserts first-responder status *within* `PickerPanel`'s own SwiftUI hierarchy, so it has zero effect on which window is *key*; it can't pull keyboard focus away from the editor while it's open. `handleNewCapture()`'s live-capture reload shares the identical async-selection shape as the debounced-search path and is deliberately included (not one of the four cases named in the routed task, but the same bug by construction) — for the same window-separation reason, refocusing from a background capture landing while the editor is open is safe, since it can't steal the editor's key status either.

**No new automated test coverage** — pure `ClipnestApp` SwiftUI/ViewModel edit, zero `ClipnestCore` touched, no App-level test target exists (D18-D22, T51, T53's own precedent, reconfirmed this session). The actual runtime behavior (does the field really keep receiving keystrokes) is an AppKit/window-server behavior no headless `swift test`/`xcodebuild` can observe — same category of gap the critique itself hit trying to script it via `osascript` (blocked by missing Accessibility/TCC grant in this sandbox, documented in the critique's own §1). Verified instead by a full hand-trace of every call site reaching either `apply*SelectionPolicy` method (confirmed none is a manual-selection path) plus clean build/lint.

**Impact.** `swift test` → 164/164 unchanged (pure App-layer change). `swift build` clean. Both lint sweeps clean. `xcodebuild` (Debug, App target) → `** BUILD SUCCEEDED **`. App not launched this session (explicit instruction) — the controller relaunches via `open` and the human verifies typing.
**Files:** `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift` (only file touched — `PickerView.swift` read, confirmed unchanged/not needed). Report: `.superpowers/sdd/2026-08-06-clipnest-plan/search-focus-fix-report.md`.

### D30 — Routed follow-up: search field is now a local `@State`, decoupled from the query entirely; `PickerViewModel.query.text` is repurposed to mean "the text a store query actually ran for," never live input  (2026-08-11, senior-dev, search-debounce-loader fix)
**The reported bug.** Even after D29's focus-race fix, typing in the picker's search field still visibly lagged: `PickerView`'s `TextField` bound straight to `viewModel.query.text` (`$viewModel.query.text`), and `query`'s `didSet` drove the debounced `ClipStore`/`SnippetStore` query — so a keystroke's character only appeared in the field once the resulting async store round-trip resolved (up to the full 400ms debounce plus real store latency). This is the standard debounced-search anti-pattern: binding the input to the thing the debounce gates.

**The fix — input and query are now two genuinely separate pieces of state.** `PickerView` gained `@State private var searchText: String = ""`, which the field binds directly (zero async in the input path — typing is always instant, independent of query latency). Every change calls the new `PickerViewModel.searchTextChanged(_:)`, which records it into a new private `currentSearchText` (the live, up-to-the-keystroke field contents), flips a new `@Published isSearching` loader flag on, and (re)starts the existing 400ms debounce. `query.text` — previously the thing typing wrote into directly — is now written in exactly one place, at the tail of `runRowsFirstPageQuery`/`runSnippetsFirstPageQuery`, once a query for that text has actually landed; it's the *applied* query, read unchanged by `ItemRow`/`SnippetRow` highlighting and the empty-state message so what's shown always matches what was actually searched, never a keystroke still in flight. `query`'s own `didSet` now only reacts to `kindFilter` changes (a chip click, still a direct live binding — a discrete, infrequent event with no lag concern) — a text-only change reaching it is recognized as "this file just synced the applied text" and is a deliberate no-op, avoiding a redundant re-query for text that was just queried.

**`isSearching` is the new loader signal**, shown by `PickerView.content` as a centered `ProgressView()` in place of the list/empty-state — so a still-in-flight query is never mistaken for a genuine "no matches" result. Set on typing (debounced), a tab switch, and a kind-filter chip change (the latter two immediate/non-debounced, but still real async store round-trips, so the loader still shows briefly); deliberately **not** touched by live-capture requeries or post-mutation window refreshes (pin/delete/snippet CRUD) — out of the routed spec's scope and those already have their own non-jarring `.softReconcile`/`.selectNear` behavior a loader flash would only interrupt.

**Two related races closed during self-review, not just asserted fixed:** (1) `PickerView`'s own `searchText = ""` reset on reopen (driven by a new `searchResetToken`, bumped once per `willShow()`, separate from `focusToken` which bumps far more often) lands one SwiftUI update cycle *after* `willShow()` already reset `currentSearchText` directly — if the field had text before the picker was last hidden, that delayed reset would otherwise re-fire `searchTextChanged`, restarting a pointless 400ms debounce and flashing the loader on every reopen-after-a-search; closed by guarding `searchTextChanged(_:)` on `text != currentSearchText`. (2) tab switches only ever cancelled the *newly active* pipeline's pending task, so a debounce left pending on the tab just switched away from could wake later and unconditionally clear `isSearching`, hiding the loader mid-flight for a genuinely in-progress query on the tab now on screen; closed by having `runActiveTabQuery` also cancel the now-inactive pipeline's task.

**The rule going forward:** any future `PickerViewModel` code that needs "what's actually in the search field right now" must read `currentSearchText`, never `query.text` — the latter can lag by up to the debounce window plus store latency by design. `flushPendingRowsQuery`/`flushPendingSnippetsQuery` (the pre-existing flush-before-commit mechanism, D25/T47) and `handleNewCapture()` were both updated to read `currentSearchText` for this reason.

**No new automated test coverage** — pure `ClipnestApp` SwiftUI/ViewModel edit, no App-level test target exists (D18-D22/T51/T53/D29's own precedent, reconfirmed this session); the actual runtime behavior (does typing feel instant, does the loader show/hide at the right moments) is not observable via headless `swift test`/`xcodebuild`. Verified instead by a full hand-trace of every trigger's `isSearching`/`query.text`/`currentSearchText` transitions (including the two races above) plus clean build/lint.

**Impact.** `swift test` → 164/164 unchanged (pure App-layer change, zero `ClipnestCore` touched). `swift build` clean. Both lint sweeps clean. `xcodegen generate` + `xcodebuild` (Debug, App target) → `** BUILD SUCCEEDED **`. App not launched this session (explicit instruction) — the controller relaunches via `open` and the human verifies typing + loader feel.
**Files:** `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift`, `ClipnestApp/Sources/UI/Picker/PickerView.swift`. Report: `.superpowers/sdd/2026-08-06-clipnest-plan/search-debounce-loader-report.md`.

### D31 — Routed follow-up: snippet editor laid out as a side-by-side pair with the picker panel (moving the picker when needed), never screen-centered and never same-left-edge stacked  (2026-08-11, senior-dev, snippet-window-placement fix, 2 rounds)
**The reported bug.** `SnippetEditorWindow` (the snippet create/edit form) opened via a plain `center()` call — always screen-centered, with zero awareness of `PickerPanel`'s actual position (which is itself anchored at the cursor, so it can be anywhere on screen). Because the two positions were computed independently, the centered editor could land directly on top of the picker.

**Round 1 (superseded — kept here for the record, not the shipped design).** New `ClipnestApp/Sources/UI/Picker/WindowPlacement.swift` with `clampedOrigin(_:size:in:)` (unchanged, still current) plus a first placement function, `besideAnchor(anchorFrame:size:screenVisibleFrame:gap:)`, that preferred right of the picker, then left, then — if neither fit fully on screen — fell back to placing the editor directly below/above the picker, reusing the picker's own `minX` as the editor's `minX`. **This round's fallback was itself the bug**: a real user screenshot (relayed by the coordinator) showed the below/above fallback firing exactly because the picker was positioned somewhere with no room on either side for the 380pt editor + 12pt gap — and same-left-edge below/above reads as a stacked, overlapping pair, i.e. the identical defect the fix was meant to eliminate. Explicit user feedback: "both left edges shouldn't be the same."

**Round 2 (shipped design).** `besideAnchor` is removed entirely (not deprioritized) and replaced by `WindowPlacement.pairLayout(pickerFrame:editorSize:screenVisibleFrame:gap:)`, which treats picker + editor as one side-by-side **pair** (`pairWidth = pickerFrame.width + gap + editorSize.width`) and is willing to **move the picker itself** to make the pair fit:
- If the pair fits the screen's `visibleFrame` width (the case on any real display — a 560pt picker + 12pt gap + 380pt editor = 952pt, well under any real screen's visible width): the picker is shifted **left only as far as needed** (never right, never resized) — `maxPickerX = screenVisibleFrame.maxX - gap - editorSize.width - pickerFrame.width`, `pickerX = max(min(currentPickerX, maxPickerX), screenVisibleFrame.minX)` — and the editor's `x` is simply `pickerX + pickerFrame.width + gap`. This is **zero overlap and a distinct left edge by construction** — the editor's `x` is always strictly greater than the picker's. If the picker's current position already leaves enough room, it isn't moved at all.
- If the pair genuinely can't fit the screen's visible width at both windows' full sizes (a pathologically narrow display): the picker is clamped on screen as-is, the editor is pushed flush against the screen's right edge (maximizing the non-overlapping region), and a guard (`if editorX <= pickerX { editorX = pickerX + 1 }`) still forces a distinct left edge even in the sub-pathological case where the editor's width alone exceeds the screen's.
- Vertically, the editor stays top-aligned to the picker's (possibly horizontally-shifted, never vertically-shifted) top edge; both origins are always run through `clampedOrigin` as a final on-screen guarantee.

`SnippetEditorWindow.show(...)` keeps its `pickerPanel: PickerPanel?` parameter (unchanged signature both rounds); `positionRelativeToPicker(_:)` now calls `pairLayout` and sets **both** frames — `pickerPanel.setFrameOrigin(pickerOrigin)` *and* its own `setFrameOrigin(editorOrigin)` — using `pickerPanel.screen.visibleFrame` (same-screen guarantee unchanged: never `.main`, never a different display). Falls back to the original `center()` call, unchanged, whenever the picker isn't currently visible or has no resolvable `.screen` (or `pickerPanel` is `nil`). Editor size (380×460, `SnippetEditorWindow.defaultSize`) is still untouched, and the picker is repositioned but never resized — only `setFrameOrigin` on either window, never `setFrame`/`setContentSize` — and activation (`NSApp.activate()` + `makeKeyAndOrderFront(nil)`) is untouched, so the editor remains a real, key-able `NSWindow` (typing/paste inside it still work exactly as before). **The picker's moved position is deliberately not restored once the editor closes** — explicit instruction not to over-engineer that; it's a non-activating panel the user can freely reposition by just reopening it (`PickerPanel.show(at:)` re-anchors at the cursor every time).

**Gap, in points, between the editor and the picker:** `12pt` (`SnippetEditorWindow.pickerPlacementGap`), unchanged both rounds, passed as `pairLayout`'s `gap:` argument.

**DRY follow-through (round 1, still current).** `PickerPanel`'s own pre-existing private `clampedOrigin(_:in:)` (used by `show(at:)`'s cursor-position clamp) had the exact same min/max clamp formula as the one this fix needed — a genuine second occurrence, not speculative — so it now delegates to `WindowPlacement.clampedOrigin` instead of keeping its own copy; `PickerPanel.show(at:)`'s observable behavior is unchanged (same formula, one owner). `PickerPanel` gained no new API for round 2's `setFrameOrigin` call — that's plain inherited `NSWindow` API, not anything `PickerPanel`-specific.

**`AppEnvironment.swift`'s one call site** (`viewModel.presentSnippetEditor`) passes `pickerPanel: panel` — the same `PickerPanel` it already weakly captured for `onClose`'s re-keying logic — into `show(...)`; doc comment updated in round 2 to note the picker may now be repositioned, not just the editor.

**No new automated test coverage** — pure `ClipnestApp`/AppKit window-positioning edit, no App-level test target exists (D18-D22/T51/T53/T54/D29/D30 precedent, reconfirmed this session via `project.yml`: only a `ClipnestApp` target, no `ClipnestAppTests`); `PickerPanel`'s own structurally identical cursor-placement/clamp logic has never had automated coverage either — window placement in this app is, by established precedent, validated by human visual check, which matches this task's own explicit instruction ("the no-overlap placement is a human visual check"). The placement math is still written as pure, deterministic functions (`CGRect`/`CGPoint`/`CGSize` in, tuple of `CGPoint`s out, zero `NSWindow`/`NSScreen` dependency) specifically so it's unit-testable the moment an App test target exists — deliberately not forcing that target into existence here, which would have been scope creep beyond a placement fix.

**Impact.** `swift test` → 164/164 unchanged both rounds (pure App-layer/AppKit change, zero `ClipnestCore` touched). `swift build` clean. Lint sweep (`ClipnestApp/Sources`) clean both rounds (round 2 needed one `swift format format --in-place` auto-wrap for a line-length violation in the new `pairLayout` body, then rebuilt/retested clean after). `xcodegen generate` + `xcodebuild` (Debug, App target) → `** BUILD SUCCEEDED **` both rounds. App not launched this session (explicit instruction) — the controller relaunches via `open` and the human visually verifies the editor now opens beside the picker with a **distinct left edge** and zero overlap, including re-checking the exact screenshot scenario if reproducible.
**Files:** `ClipnestApp/Sources/UI/Picker/WindowPlacement.swift` (new round 1, `besideAnchor` replaced by `pairLayout` in round 2), `ClipnestApp/Sources/UI/Picker/SnippetEditorWindow.swift`, `ClipnestApp/Sources/App/AppEnvironment.swift`, `ClipnestApp/Sources/UI/Picker/PickerPanel.swift` (round 1 only — unchanged round 2). Report: `.superpowers/sdd/2026-08-06-clipnest-plan/snippet-window-placement-report.md`.

### D32 — Routed follow-up: `PickerViewModel`'s Rows/Snippets paged-query pipelines extracted into one generic `PagedQuery<Element>`; the observed `rows`/`snippetRows` arrays deliberately stay on `PickerViewModel`, not the helper  (2026-08-13, senior-dev, `implementation-review.md` finding #1)
Why (the extraction): `docs/review/implementation-review.md` flagged ~250 duplicated lines across 12 methods (Rows vs Snippets — identical debounce/generation-counter/load-more shape, differing only in element type, the store fetch call, target array, and selection-policy applier); two prior fixes (D29 search-focus, D30 search-debounce/loader) each had to be hand-applied twice for exactly this reason. New `ClipnestApp/Sources/UI/Picker/PagedQuery.swift` owns everything that was byte-identical (paging, generation guard, task lifecycle); `PickerViewModel` holds two instances (`rowsQuery`/`snippetsQuery`) and its 12 methods are now thin wrappers. **Binding constraint for any future change here**: the next pipeline-shape fix (debounce timing, generation semantics, load-more bail conditions, flush behavior) should be made once in `PagedQuery.swift`, not mirrored into two call sites — if a change can't be expressed there, that's a signal the two pipelines have genuinely diverged and the shared engine needs re-examining, not silent re-duplication.
Why (item state stays on `PickerViewModel`, not `PagedQuery`): `rows`/`snippetRows` are `@Published private(set)` and `PickerView.swift` reads them directly — moving them into a `PagedQuery`-owned plain property and exposing them via a computed forwarding property would silently break SwiftUI's `objectWillChange`-driven re-render (a computed property reading a non-`@Published` source triggers no observation). `PagedQuery` instead takes `setItems`/`appendItems` closures per call and never stores the array itself. Same reasoning applies to any future "extract shared engine, keep observed state on the view model" refactor in this codebase — don't relocate `@Published` storage into a helper type unless the helper itself becomes the `ObservableObject` the view binds to directly.
Why (closures are supplied per-call, not stored once at `PagedQuery` init): the existing "snapshot search text/kind/tab at the moment a query is *scheduled*, never re-read live once a debounced/in-flight fetch actually runs" semantics (this file's pre-existing "Search-debounce + loader fix" doc comment) would silently break if `PagedQuery` stored a `fetch` closure once and that closure read `self.query.kindFilter`/`self.activeTab` live at fetch time instead. Each `PickerViewModel` wrapper method (`scheduleRowsQuery`, `refreshRowsWindow`, `loadMoreRows`, etc.) builds a fresh closure capturing already-snapshotted local `let`s at the call site instead.
Alt rejected: storing `applySelection`/`setItems`/`fetch` as closures captured at `PagedQuery`'s `init` (the task's own "recommended shape") — would require `rowsQuery`/`snippetsQuery`'s init expressions to reference `self.applyRowsSelectionPolicy`/etc. before all of `PickerViewModel`'s other stored properties (including the two `PagedQuery` properties themselves) are initialized, tripping Swift's "`self` used before all stored properties are initialized" class-init rule; `lazy var` would dodge it but adds indirection with no real benefit once closures are per-call anyway.
Impact: `PickerViewModel.swift` 1258 → 1218 lines; new `PagedQuery.swift` (231 lines). `SelectionPolicy` (nested enum) widened from `private` to internal so `PagedQuery.swift` can reference it as a parameter type — still module-only. Files: `ClipnestApp/Sources/UI/Picker/{PickerViewModel,PagedQuery}.swift`.

### D33 — Routed follow-up: SwiftData production containers self-heal from a corrupt on-disk store instead of crashing launch  (2026-08-14, senior-dev, architecture-review finding, `ClipnestCore` only)
Why: `SwiftDataClipStore`/`SwiftDataSnippetStore.makeProductionContainer()` opened the fixed production store path (`~/Library/Application Support/Clipnest/{ClipItems,Snippets}.store`) with a bare `ModelContainer(...)` call. A damaged/unreadable store file made that throw; `AppEnvironment.init` propagated it; `AppDelegate.applicationDidFinishLaunching` terminated the app with no way back in — a permanent launch crash for the affected user, worse than losing history. New shared, non-`public` `Sources/ClipnestCore/Store/ModelContainerRecovery.swift` (`ModelContainerRecovery.openWithRecovery(storeURL:logger:fileManager:makeContainer:)`) is the one place this retry/backup logic lives (DRY — mirrors `ClipStore.swift`'s existing shared `deleteBlobs(for:using:)` free function); each store still owns its own `ModelContainer(...)` call (passed in as the `makeContainer` closure) since it references that store's file-`private` `@Model` record type, which can't cross a file boundary.
**How recovery is distinguished from migration** (the load-bearing invariant): SwiftData's lightweight migration (e.g. the pre-`normalizedText` upgrade, D-whatever backs T53) runs *inside* the first `ModelContainer(...)` call — a legitimately migratable store succeeds on that first attempt and never reaches the backup path. Recovery only fires when that first call itself throws (corrupt bytes, truncated file, foreign format, unrelated schema entirely) — confirmed by re-running both stores' existing "migrates in-place without throwing" tests unchanged and green. **Binding constraint for future store-schema changes**: any new migration must keep succeeding on the *first* `ModelContainer(...)` attempt (via the usual default-value/optional-attribute lightweight-migration rules) — if a future schema change ever needs a real migration *plan* (not lightweight), this recovery path's first-attempt-success assumption needs to be re-verified against it, or a legitimately upgrading store could get wrongly backed up and wiped.
On a genuine open failure: backs up `storeURL` **and** its `-wal`/`-shm` sidecars (present or not) to sibling `<name>.corrupt-<millisecond-epoch>` files (filesystem-safe, no `DateFormatter`/locale dependency, no `:`) — sidecars matter because a stale WAL could otherwise re-corrupt the fresh store on first checkpoint. Logs the reset via the *caller's* own already-categorized `Logger` (so it shows up under `"SwiftDataClipStore"`/`"SwiftDataSnippetStore"`, not a generic category) — metadata only (backup file name, whether a backup was actually made), never store contents, per coding-standards.md's privacy rule. Retries `makeContainer` exactly once more; only a second failure (e.g. an unwritable Application Support directory) propagates as `ClipStoreError.ioFailure`/`SnippetStoreError.ioFailure`, same as before.
Both `makeProductionContainer()` methods keep their exact prior public signature (`() throws -> ModelContainer`) — zero changes needed anywhere in `ClipnestApp` (confirmed via grep: `AppEnvironment.swift` is the only call site for each, both unchanged). Each store also gained a test-only `makeRecoveringContainerForTesting(at:)`, deliberately kept separate from the pre-existing recovery-free `makeContainerForTesting(at:)` — the latter must stay recovery-free forever, since it's what the migration tests depend on to prove upgrade-not-wipe.
Impact: new `Sources/ClipnestCore/Store/ModelContainerRecovery.swift`; `SwiftDataClipStore.swift`/`SwiftDataSnippetStore.swift` (`makeProductionContainer()` routed through the helper + new `makeRecoveringContainerForTesting(at:)`); `SwiftDataClipStoreTests.swift`/`SwiftDataSnippetStoreTests.swift` (+4 tests). `swift test` 176 → 180.

### D34 — New `ClipnestAppTests` target added (closes the "zero App-level test coverage" gap the D18–D33 precedent chain kept re-flagging); the App target's actual Swift module name is `Clipnest`, not `ClipnestApp`  (2026-08-14, senior-dev, architecture-review + implementation-review findings)
Why: both reviews independently flagged this. `docs/review/architecture-review.md`'s Critical Testability finding: `PickerViewModel.swift` (1258 lines — search debounce, dual pagination pipelines, generation-counter race guards, selection policy, paste dispatch) has zero automated coverage, and three real, user-visible bugs already shipped and were only caught by manual/user report (D28's migration crash, D29's focus race, D30's search lag) — all three rooted in logic that's largely UI-framework-independent. `docs/review/implementation-review.md`'s Medium Testability finding: `WindowPlacement.clampedOrigin`/`pairLayout` are pure `CGRect`/`CGPoint`/`CGSize` math with zero AppKit dependency (the file's own doc comment says so) and had zero tests despite being "the most testable file in the entire App target." Every `PickerViewModel`/`WindowPlacement` task since D18 (T43/T47/T51/T54/T55/T56/T57) repeated the same "no App-level test target exists" line rather than fixing it — this closes that gap going forward, it doesn't retroactively add coverage for every past change.

**New target**, `ClipnestApp/project.yml`: `ClipnestAppTests` (`type: bundle.unit-test`, depends on `- target: ClipnestApp` + `ClipnestCore` directly), sources under `ClipnestApp/Tests/ClipnestAppTests/`, Swift Testing (matches D2, not XCTest). `xcodegen`'s own `- target: ClipnestApp` dependency auto-derives `TEST_HOST`/`BUNDLE_LOADER` from the *target* name — but `ClipnestApp`'s `PRODUCT_NAME` is set to `Clipnest` (see D9/T2's project.yml), so the auto-derived path pointed at a `ClipnestApp.app` that's never produced (the real product is `Clipnest.app`), and `xcodebuild test` failed with "Could not find test host." Fixed by setting `TEST_HOST`/`BUNDLE_LOADER` explicitly on the test target, matching `PRODUCT_NAME: Clipnest` — documented inline in `project.yml` as a literal that must stay in sync if the app is ever renamed again.

**Real, non-obvious discovery worth recording for every future App test file**: the `ClipnestApp` *target*'s compiled Swift module name is `Clipnest`, not `ClipnestApp` — Xcode derives the module name from `PRODUCT_NAME` when `PRODUCT_MODULE_NAME` isn't set separately, and it never was. `@testable import ClipnestApp` (the target name) fails to compile with "unable to resolve module dependency: 'ClipnestApp'"; every test file must instead write `@testable import Clipnest`. Documented at the top of every new test file so this isn't rediscovered the hard way again.

**Visibility widening — the one production-code change this task made.** `PickerViewModel.pasteContent(for:plainText:)` and `resolvedSelection<Element:>(_:currentID:result:)` were `private`; `@testable import` only elevates `internal` symbols to be visible outside the module, it does **not** reach `private`/`fileprivate` members regardless. Since these are the exact two pure decision-logic methods both reviews named (plain-vs-rich paste dispatch; hardReset/softReconcile/selectNear selection-policy resolution), both were widened to the module's default `internal` access (just dropping the `private` keyword — still invisible outside `ClipnestApp`/`Clipnest`, only now visible to this module's own test target) rather than left untested. No other production code changed.

**Tests written** (44 total, all passing): `WindowPlacementTests.swift` (9 — `clampedOrigin`'s inside/negative-edge/positive-edge/multi-screen-negative-coordinate/size-larger-than-bounds cases; `pairLayout`'s fits-unmoved/fits-shifts-left/doesn't-fit-flush-right/pathological-nudge cases, each with hand-computed expected origins, not just re-asserting current output); `ItemKind+SFSymbolTests.swift` (7 — per-case mapping + distinctness + non-empty, already `internal`, no visibility change needed); `PickerViewModelTests.swift` (28, three `@Suite`s in one file) — `pasteContent` (15: every `ItemKind` × plainText combination, including the richText-legacy-no-blob fallback, the missing-blob-on-disk error-recovery fallback for both `.richText`/`.image`, and confirming `.image`/`.file` ignore `plainText` while `.text`/`.link`/`.richText` don't), `resolvedSelection` (12: every `SelectionPolicy` case × empty/non-empty/present/absent-currentID combinations, including `.selectNear`'s out-of-bounds clamping both directions and its `nil`-index fallback to `.softReconcile`), and one deliberately-async integration test driving `willShow()` + `activeTab` switches against a real `InMemoryClipStore` (bounded `Task.yield()` polling via a new `waitUntil` test helper, never a fixed `sleep`) proving the History/Pinned tabs' inline `scope` ternary actually routes to the correct `ClipScope` — the one piece of this task's target logic that isn't reachable as a pure sync call.

**Deliberately not tested, and why**: SwiftUI rendering, real pasteboard writes, hotkey registration, the synthesized-⌘V paste path itself (already covered by `PasterTests.swift` in `ClipnestCoreTests` with the real boundary mocked there) — all out of this task's scope per its own brief. `HighlightedText.swift`'s `attributedString` is `private` and, unlike `pasteContent`/`resolvedSelection`, was judged not worth widening (it's a SwiftUI `View`'s internal rendering helper, not decision logic a bug report would trace back to) — noted as unreached rather than silently skipped.

Impact: new `ClipnestApp/Tests/ClipnestAppTests/` (4 test files + a `TestSupport/` folder of fakes: `FakePasteboardWriting`, `FakeEventSynthesizing`, `FakeFrontmostAppReferenceProviding`, `TempBlobStore`, `AsyncWaiting`, `ClipItemFixtures`, `PickerViewModelFactory` — none touches real `NSPasteboard`/`NSWorkspace`/`CGEvent`, per coding-standards.md); `ClipnestApp/project.yml` (+`ClipnestAppTests` target, scheme `test:` section); `ClipnestApp/Sources/UI/Picker/PickerViewModel.swift` (2 methods `private` → internal, doc comments only otherwise). `xcodebuild test` → **44/44 passing** (5 suites). Root `swift build && swift test` unaffected — still 180/180, zero `ClipnestCore` files touched. `swift format lint --recursive --strict ClipnestApp/Sources ClipnestApp/Tests` clean.
