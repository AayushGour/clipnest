# Clipnest — Implementation Plan

**Date:** 2026-08-06
**Status:** Ready for dev mode
**Spec:** `docs/superpowers/specs/2026-08-06-clipnest-design.md` (authoritative — this plan decomposes it, never contradicts it)
**Standards:** `.claude/coding-standards.md` — every task must match its formatter/linter/test/error-handling/layout rules
**Context:** `.claude/project-context.md` — user stories + ACs referenced below by name
**Size:** L (full team, phase-gated review/test, parallel branches where `deps` allow)

## How to read this plan

- Tasks are grouped into 5 phases matching the spec's 9 milestones (decision D4 in project-context.md). Within a phase, tasks with no dependency on each other can run **in parallel on their own branch** (L-size rule); the phase's reviewer task waits on all of that phase's build tasks, and the phase's tester task waits on the reviewer.
- Every task lists exact files (repo-relative paths), what it must do, acceptance criteria, tests to write, dependencies, and whether it's parallelizable.
- `ClipnestCore` (Phases A, most of C) lands and is unit-tested via `swift test` before any UI is built on top of it, per the spec's testability goal.
- Owners: **senior-dev** = foundational/hard logic (stores, engines, protocols), **junior-dev** = well-scoped UI/wiring work following an established pattern, **devops** = build/sign/notarize/package scripts, **reviewer**/**tester** = phase gates.
- Every build task: run `swift format lint --recursive --strict <paths>` clean, and either `swift test` (Core) or a documented manual/xcodebuild smoke check (App), before moving to `review`. Devs write unit tests themselves — no separate "write tests" task exists; tests are part of each build task's definition of done.
- Security note (applies to every task in Phases A and D especially): this app's entire purpose is handling clipboard content, which is routinely sensitive. Reviewer runs the security checklist from `coding-standards.md` (no networking imports, no logged clipboard content, concealed/transient markers un-overridable, no hardcoded notarization credentials) on **every** phase, not just once.

---

## Repo layout (target state after all tasks)

```
mac-clipboard-manager/
├── Package.swift                              # SPM package: ClipnestCore   (T2)
├── Sources/ClipnestCore/
│   ├── ClipnestCore.swift                      # placeholder marker only    (T2)
│   ├── Model/
│   │   ├── ItemKind.swift                                                  (T3)
│   │   ├── ClipItem.swift                                                  (T3)
│   │   └── Snippet.swift                                                   (T3)
│   ├── Clipboard/
│   │   ├── PasteboardReader.swift                                          (T4, extended T20)
│   │   ├── PrivacyFilter.swift                                             (T5, extended T30)
│   │   └── ClipboardMonitor.swift                                          (T7, extended T31)
│   ├── Store/
│   │   ├── ClipStore.swift                     # protocol                  (T6, extended T19,T22,T32)
│   │   ├── SwiftDataClipStore.swift                                        (T6, extended T19,T22,T32)
│   │   └── BlobStore.swift                                                 (T19)
│   ├── Search/
│   │   ├── SearchQuery.swift                                               (T11)
│   │   └── SearchFilter.swift                                              (T11)
│   └── Paste/
│       ├── EventSynthesizing.swift             # protocol                  (T15)
│       ├── FrontmostAppTracker.swift                                       (T14)
│       └── Paster.swift                                                    (T15)
├── Tests/ClipnestCoreTests/
│   ├── PasteboardReaderTests.swift                                         (T4, T20)
│   ├── PrivacyFilterTests.swift                                            (T5, T30)
│   ├── ClipStoreTests.swift                                                (T6, T19, T22, T32)
│   ├── BlobStoreTests.swift                                                (T19)
│   ├── SearchTests.swift                                                   (T11)
│   └── PasterTests.swift                                                   (T15)
├── ClipnestApp/                                 # XcodeGen project (own dir; .xcodeproj generated + gitignored)
│   ├── project.yml                                                         (T2, extended T27)
│   ├── Sources/
│   │   ├── App/
│   │   │   ├── ClipnestApp.swift                # @main, MenuBarExtra      (T2, extended T24/T29)
│   │   │   └── AppDelegate.swift                                           (T2)
│   │   ├── UI/Picker/
│   │   │   ├── PickerPanel.swift                                           (T10)
│   │   │   ├── PickerView.swift                                            (T11, extended T21,T23)
│   │   │   ├── ItemRow.swift                                               (T11, extended T21,T24)
│   │   │   ├── TabSwitcher.swift                                           (T23)
│   │   │   └── TypeFilterChips.swift                                       (T21)
│   │   ├── UI/Settings/
│   │   │   ├── SettingsView.swift                                          (T28, extended T30,T32)
│   │   │   ├── HotkeySettingsView.swift                                    (T28)
│   │   │   └── ExcludedAppsView.swift                                      (T30)
│   │   └── System/
│   │       ├── HotkeyManager.swift                                         (T27)
│   │       ├── LaunchAtLogin.swift                                         (T28)
│   │       └── PermissionsManager.swift                                    (T16)
│   └── Resources/
│       ├── Assets.xcassets/                                                (T2)
│       └── ClipnestApp.entitlements                                        (T2)
└── scripts/
    ├── build.sh                                                            (T35)
    ├── sign.sh                                                             (T36)
    ├── notarize.sh                                                         (T36)
    └── package_dmg.sh                                                      (T37)
```

---

## T2 [senior-dev] Scaffold: SPM `ClipnestCore` + XcodeGen `ClipnestApp` + menu bar launch

**Owner:** senior-dev · **Prio:** P0 · **Deps:** T1 · **Parallel:** no (everything else depends on this)

This is the foundation task — no redesign needed, the exact contents below are final. Create the files as specified.

**Files to create:**
- `Package.swift` (repo root)
- `Sources/ClipnestCore/ClipnestCore.swift` (placeholder)
- `ClipnestApp/project.yml`
- `ClipnestApp/Sources/App/ClipnestApp.swift`
- `ClipnestApp/Sources/App/AppDelegate.swift`
- `ClipnestApp/Resources/ClipnestApp.entitlements`
- `ClipnestApp/Resources/Assets.xcassets/` (minimal empty asset catalog with `Contents.json` + an `AppIcon.appiconset` placeholder; real icon art is out of scope for this task)
- `.gitignore` additions: `ClipnestApp/*.xcodeproj/`, `.build/`, `.swiftpm/`, `DerivedData/`

**`Package.swift` — exact contents:**
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipnestCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipnestCore", targets: ["ClipnestCore"])
    ],
    targets: [
        .target(name: "ClipnestCore"),
        .testTarget(name: "ClipnestCoreTests", dependencies: ["ClipnestCore"])
    ]
)
```
`Sources/ClipnestCore/ClipnestCore.swift` only needs a doc comment plus one trivial public marker (e.g. a `public let` version string) so the SPM target has ≥1 source file — this is scaffolding, not logic. T3 adds the real model types alongside/in place of it.

**`ClipnestApp/project.yml` — exact contents:**
```yaml
name: ClipnestApp
options:
  bundleIdPrefix: com.clipnest
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
packages:
  ClipnestCore:
    path: ..
targets:
  ClipnestApp:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: Sources
    resources:
      - path: Resources
    dependencies:
      - package: ClipnestCore
        product: ClipnestCore
    settings:
      base:
        PRODUCT_NAME: Clipnest
        PRODUCT_BUNDLE_IDENTIFIER: com.clipnest.app
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_ENTITLEMENTS: Resources/ClipnestApp.entitlements
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_LSUIElement: YES
        INFOPLIST_KEY_NSHumanReadableCopyright: ""
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
schemes:
  ClipnestApp:
    build:
      targets:
        ClipnestApp: all
    run:
      config: Debug
    test:
      config: Debug
```
Note: `INFOPLIST_KEY_LSUIElement: YES` + `GENERATE_INFOPLIST_FILE: YES` means no checked-in `Info.plist` is needed — Xcode synthesizes it from build settings. `DEVELOPMENT_TEAM` is intentionally omitted here (blank/ad-hoc for local unsigned builds); Phase E (T36) adds real signing settings, don't add them now.

**`ClipnestApp/Resources/ClipnestApp.entitlements` — exact contents (non-sandboxed, minimal):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
```
No `com.apple.security.app-sandbox` key (non-sandboxed direct-download app per spec). Leave empty; later tasks add entries only if a specific API genuinely requires an entitlement (note it as a decision in project-context.md if so — none of the planned APIs, CGEvent synthesis, SMAppService, SwiftData, currently require one).

**`ClipnestApp/Sources/App/ClipnestApp.swift` must:**
- Declare the `@main` SwiftUI `App` struct.
- Use `@NSApplicationDelegateAdaptor(AppDelegate.self)` to wire the AppKit delegate.
- Declare a `MenuBarExtra` scene (title "Clipnest", SF Symbol `clipboard` or similar) with `.menuBarExtraStyle(.menu)`, containing at minimum a "Quit" `Button` that calls `NSApplication.shared.terminate(nil)`. Later tasks (T24 quick menu, T27 hotkey) extend this menu — don't over-build it now.

**`ClipnestApp/Sources/App/AppDelegate.swift` must:**
- Conform to `NSApplicationDelegate`.
- In `applicationDidFinishLaunching`, set `NSApp.setActivationPolicy(.accessory)` so the app has no Dock icon and doesn't steal focus on launch (belt-and-suspenders with `LSUIElement`).

**Acceptance criteria:**
- `swift build` and `swift test` succeed from the repo root (empty/trivial Core target + test target compile and run with zero failures).
- `cd ClipnestApp && xcodegen generate` produces `ClipnestApp.xcodeproj` with no errors.
- `xcodebuild -project ClipnestApp/ClipnestApp.xcodeproj -scheme ClipnestApp -configuration Debug build` succeeds locally (unsigned).
- Running the built `.app`: a menu bar status item appears, no Dock icon is shown, clicking the status item shows a menu, "Quit" cleanly terminates the app.
- `swift format lint --recursive --strict Sources Tests` and the same against `ClipnestApp/Sources` report zero issues.

**Tests:** none beyond the build/test commands above succeeding — there is no logic yet to unit test. (This is the one task explicitly exempt from "write unit tests.")

---

## Phase A — Foundation & Capture (spec milestone 2: text-only capture pipeline)

Covers project-context.md stories: "capture," "dedup," part of "privacy filter." All of Phase A lives in `ClipnestCore` — no UI.

### T3 [junior-dev] Core model types
**Deps:** T2 · **Parallel:** no (everything in Phase A needs these)
**Files:** `Sources/ClipnestCore/Model/ItemKind.swift`, `Sources/ClipnestCore/Model/ClipItem.swift`, `Sources/ClipnestCore/Model/Snippet.swift`
**Must do:** Define `ItemKind` enum (`.text, .richText, .link, .image, .file`, `Codable`, `CaseIterable`). Define `ClipItem` as a SwiftData `@Model` class with exactly the fields from the spec: `id: UUID`, `createdAt: Date`, `kind: ItemKind`, `previewText: String`, `contentHash: String`, `pinned: Bool`, `sourceAppName: String?`, `sourceBundleID: String?`, `byteSize: Int`, `blobPath: String?`. Define `Snippet` as a SwiftData `@Model` class: `id: UUID`, `title: String`, `body: String`, `keyword: String?`, `createdAt: Date`. Both need a memberwise-equivalent initializer since `@Model` synthesis varies by field defaults — give every field a sensible default or explicit initializer so call sites don't need to fight synthesis.
**AC:** Both types compile as valid SwiftData models (usable in a `ModelContainer` in a test); `ItemKind` round-trips through `Codable`.
**Tests:** `ItemKind` `Codable` round-trip; `ClipItem`/`Snippet` can be inserted into and fetched from an in-memory `ModelContainer` (`isStoredInMemoryOnly: true`) with all fields preserved. Add these as a small `ModelTests.swift` or fold into `ClipStoreTests.swift` (T6 will own the full CRUD suite; a minimal insert/fetch smoke test here is enough to prove the models are valid).

### T4 [senior-dev] `PasteboardReader` — text classification + hashing
**Deps:** T3 · **Parallel:** yes (with T5, T6)
**Files:** `Sources/ClipnestCore/Clipboard/PasteboardReader.swift`, `Tests/ClipnestCoreTests/PasteboardReaderTests.swift`
**Must do:** A `PasteboardReader` type that, given an `NSPasteboard` (or an injected abstraction over it — prefer a small protocol like `PasteboardReading` so tests don't need a real `NSPasteboard`), inspects available UTI types and produces a `(kind: ItemKind, previewText: String, contentHash: String, byteSize: Int)` tuple for `.text`, `.richText`, and `.link` (URL detection via `NSDataDetector` or `URL(string:)` validation on plain text). `.image`/`.file` classification is stubbed to return `nil`/unsupported for now — T20 implements those once `BlobStore` exists (T19); don't build blob-writing logic here. `contentHash` = SHA256 (via `CryptoKit`) of the canonical text bytes.
**AC:** Given pasteboard content of plain text, rich text (RTF), and a URL string, returns the correct `ItemKind` and a stable hash (same input → same hash across calls).
**Tests:** one case per kind in `PasteboardReaderTests`, plus a hash-stability test (same content twice → identical `contentHash`) and a hash-difference test (different content → different hash).

### T5 [senior-dev] `PrivacyFilter` — concealed/transient + exclusions
**Deps:** T3 · **Parallel:** yes (with T4, T6)
**Files:** `Sources/ClipnestCore/Clipboard/PrivacyFilter.swift`, `Tests/ClipnestCoreTests/PrivacyFilterTests.swift`
**Must do:** A `PrivacyFilter` type with a method like `shouldCapture(availableTypes: [NSPasteboard.PasteboardType], sourceBundleID: String?, isPaused: Bool) -> Bool`. Reject unconditionally if `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType` is present in `availableTypes` — this check must not be bypassable by any parameter. Reject if `isPaused` is true. Reject if `sourceBundleID` is in a built-in password-manager list (web-search current bundle IDs for 1Password/Bitwarden/LastPass/Dashlane/Keeper before hardcoding — see project-context.md Assumptions) merged with a caller-supplied custom exclude `Set<String>` (the caller/Settings layer owns persistence of the custom list; this type just takes it as input — no `UserDefaults` reads inside `ClipnestCore`).
**AC:** Concealed/transient markers always reject regardless of other params. Built-in and custom excluded bundle IDs reject. Pause flag rejects everything. Normal text from a non-excluded app is accepted.
**Tests:** one test per rejection reason listed above, plus one happy-path acceptance test, in `PrivacyFilterTests`.

### T6 [senior-dev] `ClipStore` protocol + `SwiftDataClipStore` — CRUD, dedup, text
**Deps:** T3 · **Parallel:** yes (with T4, T5)
**Files:** `Sources/ClipnestCore/Store/ClipStore.swift`, `Sources/ClipnestCore/Store/SwiftDataClipStore.swift`, `Tests/ClipnestCoreTests/ClipStoreTests.swift`
**Must do:** Define `protocol ClipStore` with `async throws` methods: `insertOrBumpDuplicate(_ item: ClipItem) throws -> ClipItem` (if an existing item has the same `contentHash`, update its `createdAt`/ordering instead of inserting a new row — this is the dedup rule), `fetchAll(matching query: SearchQuery?) throws -> [ClipItem]` (accept `nil`/a not-yet-built `SearchQuery` gracefully — T11 fills in real filtering; for now this can just return all items sorted by `createdAt` descending when no query is given), `setPinned(_ id: UUID, pinned: Bool) throws`, `delete(_ id: UUID) throws`, `clearHistory() throws`. Concrete `SwiftDataClipStore` implements it against a `ModelContainer`/`ModelContext`. Use a typed `ClipStoreError` enum per coding-standards.md (`.notFound`, `.ioFailure(underlying: String)`).
**AC:** Inserting the same `contentHash` twice results in exactly one row, with `createdAt` updated to the second insert's time. Pin/unpin, delete, and clear-history all behave as described. `fetchAll` returns newest-first by default.
**Tests:** dedup collapse, pin/unpin toggling, delete removes exactly one item, clear-history empties the store, fetchAll ordering — all in `ClipStoreTests` against an in-memory `ModelContainer`.

### T7 [senior-dev] `ClipboardMonitor` — polling orchestration
**Deps:** T4, T5, T6 · **Parallel:** no (needs all three above)
**Files:** `Sources/ClipnestCore/Clipboard/ClipboardMonitor.swift`
**Must do:** A `ClipboardMonitor` that polls `NSPasteboard.general.changeCount` on a `Timer` (~0.4s interval, injectable for tests so tests don't sleep real wall-clock time — accept an interval and a timer-scheduling abstraction, or expose a `checkNow()` method tests call directly instead of waiting on a real timer). On a change-count delta: read available types, run them through `PrivacyFilter.shouldCapture`; if accepted, hand the pasteboard to `PasteboardReader`, build a `ClipItem`, and call `ClipStore.insertOrBumpDuplicate`. Exposes a `pause()`/`resume()` (backs the "Pause capture" story; T31 wires this to UI, this task just needs the flag to exist and be honored). Constructor takes `ClipStore` and `PrivacyFilter` (and reader) as injected dependencies — no singletons.
**AC:** On a simulated pasteboard change with acceptable content, exactly one `ClipItem` appears in the injected `ClipStore`. On a change with concealed/transient markers, nothing is inserted. While paused, no changes are captured even if the pasteboard changes.
**Tests:** wire a fake/in-memory `ClipStore` (or the real `SwiftDataClipStore` with an in-memory container) + a real `PrivacyFilter`, drive `checkNow()` (not a real timer) with controlled pasteboard state, assert store contents. Cover: normal capture, concealed-marker rejection, pause behavior.

### T8 [reviewer] Review Phase A (T3–T7)
**Deps:** T3, T4, T5, T6, T7 · **Parallel:** no
**Must do:** Independent review of all Phase A code + how the pieces integrate (`ClipboardMonitor` wiring `PasteboardReader`+`PrivacyFilter`+`ClipStore` correctly). Run the **mandatory security pass** from coding-standards.md: confirm no networking imports anywhere, confirm `PrivacyFilter`'s concealed/transient check truly cannot be bypassed by any code path, confirm nothing logs raw clipboard content. Check `swift format lint --recursive --strict Sources Tests` is clean and `swift test` is green. Reject back to the relevant task's owner (senior-dev/junior-dev) with specific findings if anything fails; otherwise move tasks to `status:test`.
**AC:** All findings resolved or explicitly accepted with rationale; lint clean; `swift test` green.

### T9 [tester] Validate Phase A vs acceptance criteria
**Deps:** T8 · **Parallel:** no
**Must do:** Run `swift test` from repo root, paste the actual output into the board note + `.claude/logs/tester.md`. Verify against project-context.md stories: capture (new `ClipItem` per accepted change), dedup (identical copies collapse), privacy filter (concealed/transient/excluded/paused all reject). Only tester may set these tasks to `status:done` (integrity rule 2) — do so once evidence is pasted.
**AC:** Pasted `swift test` output shows 0 failures; each Phase A story's AC is checked off explicitly in the board note.

---

## Phase B — Picker & Paste (spec milestones 3 + 4)

Covers stories: "search," "paste + Accessibility fallback." Introduces the `ClipnestApp` UI for the first time.

### T10 [senior-dev] `PickerPanel` — non-activating floating panel shell
**Deps:** T2 · **Parallel:** yes (with T4–T9, since it only needs the app scaffold, not Core's capture logic)
**Files:** `ClipnestApp/Sources/UI/Picker/PickerPanel.swift`
**Must do:** An `NSPanel` subclass or factory configured borderless, non-activating (`.nonactivatingPanel` style mask, `level = .floating`, `becomesKeyOnlyIfNeeded` / equivalent so it never steals focus from the frontmost app), hosting a SwiftUI view via `NSHostingView`. Exposes `show(at point: CGPoint?)` (nil = center-ish/cursor default) and `hide()`. No picker *content* yet — that's T11; this task is purely the window-chrome shell, testable by manual smoke check (opening/closing without crashing, without activating the app / stealing focus from Terminal or another app).
**AC:** Calling `show()` displays the panel without bringing Clipnest to the foreground (verify: focus another app, trigger show, confirm that app's window still shows as key). `hide()`/Esc-equivalent dismisses it.
**Tests:** light smoke test only per spec ("UI kept thin"); no Core logic to unit test here.

### T11 [senior-dev] `PickerView` + `ItemRow` + search + History tab
**Deps:** T6, T10 · **Parallel:** no
**Files:** `ClipnestApp/Sources/UI/Picker/PickerView.swift`, `ClipnestApp/Sources/UI/Picker/ItemRow.swift`, `Sources/ClipnestCore/Search/SearchQuery.swift`, `Sources/ClipnestCore/Search/SearchFilter.swift`, `Tests/ClipnestCoreTests/SearchTests.swift`
**Must do:** In `ClipnestCore`: `SearchQuery { text: String, kindFilter: ItemKind? }` and a pure filtering function/type (`SearchFilter`) that takes `[ClipItem]` + `SearchQuery` and returns matches (case-insensitive substring match on `previewText`, optional kind filter) — this must be usable and tested with zero UI. In `ClipnestApp`: `PickerView` (SwiftUI) with an auto-focused search `TextField` bound to a `SearchQuery`, a virtualized/`List`-based row of `ItemRow`s sourced from `ClipStore.fetchAll` filtered live via `SearchFilter`, and a History tab (the only tab this task builds — Pinned/Snippets come in T23). `ItemRow` renders `previewText` + kind icon + relative timestamp.
**AC:** Typing in the search field filters the visible list live, case-insensitively, against real `ClipStore` data.
**Tests:** `SearchTests` covers `SearchFilter` standalone (empty query returns all, text match, kind filter, no-match returns empty) with zero UI/App-target dependency — this is the part that must be testable via plain `swift test`.

### T12 [junior-dev] Copy-to-clipboard on select
**Deps:** T11 · **Parallel:** yes (with T13)
**Files:** `ClipnestApp/Sources/UI/Picker/PickerView.swift` (extend), `ClipnestApp/Sources/UI/Picker/ItemRow.swift` (extend)
**Must do:** Selecting a row (click or Enter) writes that item's content back onto `NSPasteboard.general` and dismisses the panel (calls `PickerPanel.hide()`). Text-only for now (image/file paste comes with T21 once those kinds exist).
**AC:** Selecting a text item places its exact content on the system clipboard (verify by reading `NSPasteboard.general` after selection) and the panel closes.
**Tests:** smoke-level (UI); no new Core logic.

### T13 [junior-dev] Keyboard navigation
**Deps:** T11 · **Parallel:** yes (with T12)
**Files:** `ClipnestApp/Sources/UI/Picker/PickerView.swift` (extend)
**Must do:** ↑/↓ moves the row selection (wrapping or clamping — clamp at list edges), Enter activates the current selection (reuses T12's select action), Esc calls `PickerPanel.hide()`, ⌘F focuses the search field.
**AC:** All four key behaviors work without the mouse, verified manually/documented in the task's own log since this is UI-only.
**Tests:** smoke-level (UI); no new Core logic.

### T14 [junior-dev] `FrontmostAppTracker`
**Deps:** T2 · **Parallel:** yes (independent of T10–T13)
**Files:** `Sources/ClipnestCore/Paste/FrontmostAppTracker.swift`
**Must do:** A small type that, when told "picker is about to open," records `NSWorkspace.shared.frontmostApplication` (bundle ID + `NSRunningApplication` reference) so the paste step (T15) knows which app to target — because once the picker panel is shown, *it* may not become frontmost (non-activating), but capturing the "who was frontmost right before" is still needed for a reliable target and needs to happen before any transient focus changes.
**AC:** Given a mocked "current frontmost app" provider, correctly records and exposes it; a second call to "record" before "consume" overwrites (last-recorded wins).
**Tests:** unit test with an injected frontmost-app provider abstraction (don't depend on real `NSWorkspace` state in tests — inject a protocol).

### T15 [senior-dev] `Paster` — CGEvent synthesis with injectable event synthesizer
**Deps:** T14, T6 · **Parallel:** no
**Files:** `Sources/ClipnestCore/Paste/EventSynthesizing.swift`, `Sources/ClipnestCore/Paste/Paster.swift`, `Tests/ClipnestCoreTests/PasterTests.swift`
**Must do:** `protocol EventSynthesizing { func synthesizeCommandV(targeting app: FrontmostAppRef) throws }` (name types to match T14's tracker) with a real `CGEvent`-based implementation (`CGEventCreateKeyboardEvent` for ⌘ down, V down, V up, ⌘ up, posted via `CGEvent.post` or targeted via `postToPid` if targeting a specific process). `Paster` takes a `ClipStore`-independent "content to paste" (text for now; T21 adds image/file), writes it to `NSPasteboard.general`, then — **only if Accessibility is granted** — calls the injected `EventSynthesizing` to send ⌘V to the previously-frontmost app from `FrontmostAppTracker`. If Accessibility is not granted, stop after the clipboard write (no error, no crash — this is the documented fallback behavior, not a failure state). Define `PasteError` per coding-standards.md for genuine failures (e.g. `.eventPostFailed`).
**AC:** With a mocked `EventSynthesizing` and Accessibility "granted" state, `Paster` calls the mock exactly once with the right target after writing to the pasteboard. With Accessibility "not granted," `Paster` still writes to the pasteboard and returns normally without invoking the synthesizer.
**Tests:** both branches above in `PasterTests`, using a mock `EventSynthesizing` — **no real key events synthesized in CI**, matching the spec's explicit testing requirement.

### T16 [senior-dev] `PermissionsManager` + Accessibility fallback wired into the paste flow
**Deps:** T15, T12 · **Parallel:** no
**Files:** `ClipnestApp/Sources/System/PermissionsManager.swift`, `ClipnestApp/Sources/UI/Picker/PickerView.swift` (extend: Enter now calls `Paster` instead of only writing the pasteboard)
**Must do:** `PermissionsManager` wraps `AXIsProcessTrusted()` (and a prompting variant using the `kAXTrustedCheckOptionPrompt` option for use from Settings, T28) and exposes current status. Wire the picker's Enter/select action to go through `Paster` (which now performs the real synthesized paste when possible, else the T12 clipboard-only fallback) instead of the T12 stub.
**AC:** With Accessibility granted, selecting an item in the picker pastes into the previously-frontmost app end-to-end. Without it, the item still lands on the clipboard and the app doesn't crash or hang waiting on a permission it doesn't have.
**Tests:** `PermissionsManager` itself is a thin AppKit wrapper — smoke-level; the branching logic it feeds is already covered by T15's `PasterTests`.

### T17 [reviewer] Review Phase B (T10–T16)
**Deps:** T10, T11, T12, T13, T14, T15, T16 · **Parallel:** no
**Must do:** Same review discipline as T8: correctness, integration (does the picker really never steal focus; does paste really degrade gracefully without Accessibility), standards conformance, mandatory security pass (still no networking imports; nothing about the paste path logs pasted content). Confirm `swift test` green and lint clean on all touched files.
**AC:** Findings resolved; lint clean; tests green.

### T18 [tester] Validate Phase B vs acceptance criteria
**Deps:** T17 · **Parallel:** no
**Must do:** Run `swift test`, paste output. Manually verify (documented steps in the log, since this is UI/AppKit behavior `swift test` can't cover): picker opens without stealing focus, search filters live, ↑/↓/Enter/Esc/⌘F all work, paste works with Accessibility granted and degrades correctly without it. Set to `done` once evidence is recorded.
**AC:** Evidence pasted for both the automated (`swift test`) and manual checks; each Phase B story's AC explicitly checked off.

---

## Phase C — Rich Content, Pin, Snippets (spec milestones 5 + 6)

Covers stories: "images/files via BlobStore," "pin," "snippets."

### T19 [senior-dev] `BlobStore` — content-addressed blob write/read/dedup
**Deps:** T2 · **Parallel:** yes (independent of Phase B; only needs the scaffold)
**Files:** `Sources/ClipnestCore/Store/BlobStore.swift`, `Tests/ClipnestCoreTests/BlobStoreTests.swift`
**Must do:** `BlobStore` writes arbitrary `Data` to `~/Library/Application Support/Clipnest/blobs/<sha256-hash>` (create the directory if missing), returns the relative `blobPath` to store on a `ClipItem`, and a `read(blobPath:) throws -> Data`. Writing identical bytes twice must not create a second file (check-before-write by hash, or write-then-detect-collision — either way, `BlobStoreTests` proves only one file exists after two identical writes). Provide a way to override the base directory for tests (inject the root path, don't hardcode `FileManager.default.homeDirectoryForCurrentUser` inside the type with no seam).
**AC:** Round-trip write→read returns identical bytes. Two identical writes result in exactly one file on disk. A `delete(blobPath:)` removes the file (used by retention/clear-history later).
**Tests:** write/read round-trip, dedup-on-identical-bytes, delete removes the file, reading a nonexistent path throws a typed error — all in `BlobStoreTests` against a temp directory (never the real `~/Library/Application Support`).

### T20 [senior-dev] Extend `PasteboardReader` + `ClipStore` for image/file/link via `BlobStore`
**Deps:** T4, T6, T19 · **Parallel:** no
**Files:** `Sources/ClipnestCore/Clipboard/PasteboardReader.swift` (extend), `Sources/ClipnestCore/Store/SwiftDataClipStore.swift` (extend if needed for blob cleanup on delete), `Tests/ClipnestCoreTests/PasteboardReaderTests.swift` (extend)
**Must do:** Fill in the `.image`/`.file` classification T4 stubbed out: for `.image`, read the image bytes (e.g. from `NSPasteboard.PasteboardType.tiff`/`.png`), hash them, write via `BlobStore`, set `blobPath` + `byteSize` on the resulting `ClipItem`, `previewText` = something reasonable (e.g. "Image, WxH" or a size string — exact copy is a UI concern, keep it simple/factual here). For `.file`, capture enough metadata (file URL/promise data) to re-offer the file reference on paste, with `previewText` = filename. Ensure `ClipStore.delete`/`clearHistory` also delete the associated blob via `BlobStore.delete` — no orphaned blobs.
**AC:** Copying an image produces a `ClipItem` with kind `.image`, a valid `blobPath`, and correct `byteSize`. Copying the same image twice reuses the same blob (via T19's dedup). Deleting an item with a blob removes the blob file too.
**Tests:** extend `PasteboardReaderTests` with image + file cases (use small in-memory fixture data, not real screenshots); extend `ClipStoreTests`/`BlobStoreTests` with a delete-cleans-up-blob case.

### T21 [junior-dev] Picker UI: image/file/link previews + type-filter chips
**Deps:** T11, T20 · **Parallel:** yes (with T22, once T20 lands)
**Files:** `ClipnestApp/Sources/UI/Picker/ItemRow.swift` (extend), `ClipnestApp/Sources/UI/Picker/TypeFilterChips.swift`, `ClipnestApp/Sources/UI/Picker/PickerView.swift` (extend), `ClipnestApp/Sources/Paste/...` paste path extension for non-text kinds (reuse T15/T16's `Paster`, extended to accept image/file payloads, not just text)
**Must do:** `ItemRow` renders a thumbnail for `.image` (load bytes via `BlobStore.read`), a file icon + name for `.file`, a clickable-looking link style for `.link`. `TypeFilterChips` (All/Text/Image/File/Link) filters the list via `SearchQuery.kindFilter` (already defined in T11). Selecting an image/file item pastes it correctly (writes the right pasteboard type(s), not just plain text).
**AC:** Each kind renders distinctly and correctly in the list; selecting a filter chip narrows the list to that kind; selecting/pasting an image or file item round-trips correctly into another app.
**Tests:** UI smoke-level; the underlying classification/store logic is already covered by T20's Core tests.

### T22 [senior-dev] Pin/unpin + `Snippet` CRUD
**Deps:** T6 · **Parallel:** yes (with T19, T20, T21 — independent subsystem)
**Files:** `Sources/ClipnestCore/Store/ClipStore.swift` (extend — `setPinned` already exists from T6, add `fetchPinned()` convenience if useful), `Sources/ClipnestCore/Store/SwiftDataClipStore.swift` (extend), a `SnippetStore` protocol + `SwiftDataSnippetStore` (new, mirrors `ClipStore`'s shape: create/update/delete/fetchAll for `Snippet`) — file: `Sources/ClipnestCore/Store/SnippetStore.swift`
**Must do:** Confirm/extend pin/unpin (T6 already has `setPinned`; add a `fetchAll` variant or query option that surfaces only pinned items for the Pinned tab). Add full `Snippet` CRUD (`SnippetStore` protocol + SwiftData impl): create, update (title/body/keyword), delete, fetchAll.
**AC:** Pinned items are retrievable as a distinct set. Snippets can be created, edited, deleted, and listed.
**Tests:** extend `ClipStoreTests` with a "fetch pinned only" case; new `SnippetStoreTests.swift` (or fold into `ClipStoreTests.swift` if the file stays small) covering full CRUD.

### T23 [junior-dev] Pinned + Snippets tabs UI
**Deps:** T11, T22 · **Parallel:** no
**Files:** `ClipnestApp/Sources/UI/Picker/TabSwitcher.swift`, `ClipnestApp/Sources/UI/Picker/PickerView.swift` (extend)
**Must do:** `TabSwitcher` renders History/Pinned/Snippets with ⌘1/⌘2/⌘3 shortcuts, switching which data source `PickerView`'s list reads from (`ClipStore.fetchAll` w/ pinned filter, vs `SnippetStore.fetchAll`). Snippets tab needs a minimal create/edit affordance (title, body, optional keyword field — a simple form/sheet is fine, don't over-design beyond the spec).
**AC:** ⌘1/⌘2/⌘3 switch tabs; Pinned shows only pinned items; Snippets shows created snippets and supports create/edit/delete; selecting a snippet pastes its body via the same paste path as history items (reuses T15/T16/T21's `Paster`).
**Tests:** UI smoke-level; store logic already covered by T22.

### T24 [junior-dev] Row actions: pin/unpin/delete
**Deps:** T23 · **Parallel:** no
**Files:** `ClipnestApp/Sources/UI/Picker/ItemRow.swift` (extend), `ClipnestApp/Sources/UI/Picker/PickerView.swift` (extend)
**Must do:** Add a row-level action (context menu and/or hover button) for pin/unpin and delete, plus a keyboard shortcut for each (e.g. ⌘P pin, ⌘⌫ delete) applied to the currently-selected row.
**AC:** Pin/unpin/delete all work from the keyboard and from a row action, immediately reflected in the list (item moves to/from Pinned tab, or disappears on delete).
**Tests:** UI smoke-level; underlying store operations already covered by T6/T22.

### T25 [reviewer] Review Phase C (T19–T24)
**Deps:** T19, T20, T21, T22, T23, T24 · **Parallel:** no
**Must do:** Standard review + integration check (does blob cleanup really happen on delete/clear; do pin and snippet flows share the paste path correctly instead of duplicating it) + mandatory security pass (still no networking; blob files aren't world-readable in a way that leaks — default `FileManager` permissions in the user's own `Application Support` are fine, just confirm no accidental broader permissions were set). Confirm lint clean and `swift test` green.
**AC:** Findings resolved; lint clean; tests green.

### T26 [tester] Validate Phase C vs acceptance criteria
**Deps:** T25 · **Parallel:** no
**Must do:** Run `swift test`, paste output. Manually verify images/files/links capture and paste correctly, pin/unpin persists and filters correctly, snippets CRUD + paste work. Set to `done` once evidence is recorded.
**AC:** Evidence pasted; each Phase C story's AC explicitly checked off.

---

## Phase D — Hotkey, Settings, Privacy Controls, Retention (spec milestones 7 + 8)

Covers stories: "settings," rest of "privacy filter" (exclusions UI, pause), "retention."

### T27 [senior-dev] Add `KeyboardShortcuts` dependency + `HotkeyManager`
**Deps:** T2, T10 · **Parallel:** yes (with T28's non-hotkey parts once split, but simplest as sequential — see note)
**Files:** `ClipnestApp/project.yml` (extend: add the `KeyboardShortcuts` package — see below), `ClipnestApp/Sources/System/HotkeyManager.swift`, `ClipnestApp/Sources/App/ClipnestApp.swift` (extend: register the default shortcut at launch)
**Must do:** **Before editing `project.yml`:** verify the current latest stable release tag and MIT license of `KeyboardShortcuts` at `github.com/sindresorhus/KeyboardShortcuts` (web search / check the repo directly — do not trust a version number baked into this plan, it may be stale; decision D5 in project-context.md). Add a `packages:` entry:
```yaml
  KeyboardShortcuts:
    url: https://github.com/sindresorhus/KeyboardShortcuts
    from: "<verified current major version>"
```
and a `dependencies:` entry `- package: KeyboardShortcuts` under the `ClipnestApp` target. Regenerate with `xcodegen generate`. Define a `KeyboardShortcuts.Name` for the picker toggle (default ⌘⇧V — set via `KeyboardShortcuts.setShortcut` on first launch if unset) and an `onKeyUp` handler that calls `PickerPanel.show(at:)` at the current mouse cursor location.
**AC:** Pressing ⌘⇧V from any app opens the picker at the cursor without stealing focus from the app that was frontmost.
**Tests:** UI/system-level smoke check (document manual verification steps); `HotkeyManager`'s own logic (which name maps to which action) can have a thin unit test if structured as a pure mapping, but the global-hotkey registration itself is inherently not unit-testable — don't force it.

### T28 [junior-dev] Settings window: hotkey recorder, launch-at-login, storage usage, clear-history
**Deps:** T27, T6, T19 · **Parallel:** yes (with T29)
**Files:** `ClipnestApp/Sources/UI/Settings/SettingsView.swift`, `ClipnestApp/Sources/UI/Settings/HotkeySettingsView.swift`, `ClipnestApp/Sources/System/LaunchAtLogin.swift`, `ClipnestApp/Sources/App/ClipnestApp.swift` (extend: add a SwiftUI `Settings` scene)
**Must do:** `HotkeySettingsView` embeds `KeyboardShortcuts.Recorder` bound to T27's `Name`. `LaunchAtLogin` wraps `SMAppService.mainApp.register()`/`.unregister()` behind a simple toggle-friendly API (`var isEnabled: Bool { get set }` or similar, with error surfacing — registering can throw). `SettingsView` composes: hotkey recorder, launch-at-login toggle, storage usage (sum of SwiftData store size + `BlobStore` directory size — read-only display), and a "Clear history" button that shows a confirmation alert before calling `ClipStore.clearHistory()` **and** deleting all blobs (per project-context.md's Clear History assumption — confirm this still matches product intent before shipping; flagged, not silently resolved).
**AC:** Settings window opens (⌘, or via app menu), recorder changes the active hotkey live, launch-at-login toggle actually registers/unregisters the app, storage usage reflects real disk usage, Clear History requires confirmation and then empties both the DB and the blobs directory.
**Tests:** UI/system smoke-level; `ClipStore.clearHistory()` + blob deletion already covered by Core tests (T6/T19/T20).

### T29 [junior-dev] Menu bar right-click quick menu
**Deps:** T2, T7 · **Parallel:** yes (with T27, T28)
**Files:** `ClipnestApp/Sources/App/ClipnestApp.swift` (extend)
**Must do:** Extend the `MenuBarExtra` menu (left-click already opens picker via T27's hotkey path — reuse the same action for a menu item too) to include, on right-click or as always-visible items: "Settings…" (opens the Settings scene), "Pause capture" (toggle, wired to `ClipboardMonitor.pause()`/`.resume()` from T7), "Quit" (already exists from T2).
**AC:** All three menu actions work; "Pause capture" visibly reflects its current state (checkmark/label change) and actually stops new captures when engaged.
**Tests:** UI smoke-level; `ClipboardMonitor.pause()/resume()` logic already covered by T7's Core tests — this task is wiring only.

### T30 [senior-dev] Excluded-apps settings wired into `PrivacyFilter`
**Deps:** T5, T28 · **Parallel:** no
**Files:** `ClipnestApp/Sources/UI/Settings/ExcludedAppsView.swift`, `ClipnestApp/Sources/UI/Settings/SettingsView.swift` (extend), `ClipnestApp/Sources/App/ClipnestApp.swift` or a small app-level settings-persistence type (extend — persist the custom exclude list via `UserDefaults`, App-layer only, never inside `ClipnestCore` per T5's design)
**Must do:** `ExcludedAppsView` lists currently-excluded bundle IDs (built-in list read-only/shown for transparency + user-added list, editable: add via an app picker or bundle-ID text entry, remove via row action). Persist the custom list (`UserDefaults` in the App layer) and pass it into `PrivacyFilter.shouldCapture` on every check (`ClipboardMonitor` reads the current custom list each poll or on change — don't let it go stale).
**AC:** Adding an app to the exclude list immediately stops new captures sourced from that app; removing it resumes capture from that app. Built-in exclusions remain in effect regardless of the custom list's contents.
**Tests:** `PrivacyFilter`'s core logic already covered by T5's tests (custom-set parameter); this task's own test is UI/wiring smoke-level, but explicitly verify (manually, documented) that toggling the list changes real capture behavior end-to-end — this is a security-relevant task, be thorough. **Mandatory security pass emphasis for the reviewer on this task** per coding-standards.md.

### T31 [junior-dev] Pause capture end-to-end
**Deps:** T29, T7 · **Parallel:** yes (with T30, if branched separately)
**Files:** `ClipnestApp/Sources/App/ClipnestApp.swift` (extend, if not already fully wired by T29)
**Must do:** Confirm/finish the wiring so both the menu toggle (T29) and any Settings-side pause control reflect and control the same underlying `ClipboardMonitor.pause()/resume()` state (single source of truth — don't let menu and Settings desync). If T29 already fully wires this, this task reduces to verification + adding a Settings-side toggle if the spec's "Pause capture (menu + Settings)" wants it in both places — check `SettingsView` from T28 and add it there too if missing.
**AC:** Pausing from either surface (menu or Settings) is reflected in both places and actually stops capture; resuming likewise.
**Tests:** UI smoke-level; core pause logic already covered by T7.

### T32 [senior-dev] Retention cap + Clear-history full wipe
**Deps:** T6, T19, T28 · **Parallel:** no
**Files:** `Sources/ClipnestCore/Store/ClipStore.swift` (extend: add a retention-cleanup method), `Sources/ClipnestCore/Store/SwiftDataClipStore.swift` (extend), `Tests/ClipnestCoreTests/ClipStoreTests.swift` (extend), `ClipnestApp/Sources/UI/Settings/SettingsView.swift` (extend: count/age cap controls, default off)
**Must do:** In Core: a `enforceRetention(cap: RetentionCap?) throws` (or similar) method on `ClipStore` — `RetentionCap` models either a max item count or a max age, `nil`/unset = no cap (default, keep everything). When a cap is set, delete unpinned items beyond the cap (oldest first) **and their blobs** via `BlobStore.delete`; pinned items are never touched by this method regardless of cap. In App: Settings UI to configure the cap (off by default, matching the spec), calling `enforceRetention` after changes and periodically (e.g. after each capture, or on a timer — keep it simple, correctness over cleverness).
**AC:** With no cap, nothing is auto-deleted no matter how much history accumulates. With a count cap of N, the store never exceeds N unpinned items after cleanup runs; pinned items are always retained regardless of the cap.
**Tests:** `ClipStoreTests` cases: no-cap leaves everything, count-cap trims oldest-first, pinned items survive a cap that would otherwise delete them, associated blobs are deleted alongside trimmed items.

### T33 [reviewer] Review Phase D (T27–T32)
**Deps:** T27, T28, T29, T30, T31, T32 · **Parallel:** no
**Must do:** Standard review + integration check + **mandatory security pass with extra scrutiny** (this phase is where user-controlled exclusions and pause state live — confirm the built-in concealed/transient rule from T5 truly cannot be weakened by anything added here, confirm the custom exclude list can only *add* restrictions never remove the mandatory ones, confirm `UserDefaults` persistence doesn't accidentally store anything sensitive). Confirm lint clean, `swift test` green.
**AC:** Findings resolved; lint clean; tests green.

### T34 [tester] Validate Phase D vs acceptance criteria
**Deps:** T33 · **Parallel:** no
**Must do:** Run `swift test`, paste output. Manually verify hotkey opens picker without stealing focus, Settings controls all function (hotkey recorder, launch-at-login, exclusions, retention cap, clear history with confirmation), pause works from both surfaces. Set to `done` once evidence is recorded.
**AC:** Evidence pasted; each Phase D story's AC explicitly checked off, including the security-sensitive ones (exclusions, concealed/transient non-bypassability).

---

## Phase E — Signing, Notarization, DMG (spec milestone 9)

Covers the distribution constraint in project-context.md (requires the user's own Apple Developer account — devops scripts must be correct and account-agnostic, not something that can be fully verified without live credentials).

### T35 [devops] Build script
**Deps:** T2 · **Parallel:** yes (can be authored anytime after scaffolding; real end-to-end DMG validation waits on T34 via T39)
**Files:** `scripts/build.sh`
**Must do:** A shell script that runs `xcodegen generate` in `ClipnestApp/`, then `xcodebuild -project ClipnestApp/ClipnestApp.xcodeproj -scheme ClipnestApp -configuration Release archive -archivePath build/Clipnest.xcarchive`, then exports a `.app` from the archive (`xcodebuild -exportArchive` with an export options plist for Developer ID, or a direct copy from the archive's `Products/Applications` if export options aren't ready yet — keep this script buildable/runnable without requiring signing to already work, since T36 owns signing specifics). Fail loudly (non-zero exit, clear message) on any step failure — no silent partial builds.
**AC:** Running `scripts/build.sh` from repo root produces a `Clipnest.app` in a known `build/` output location, using only the generated Xcode project (no manual Xcode steps).
**Tests:** devops runs the script and pastes the actual terminal output as evidence; no unit tests apply to a shell script, but a lint pass with `shellcheck` (if available) is good practice — note in the log if `shellcheck` isn't available in the environment rather than skipping silently.

### T36 [devops] Sign + notarize scripts
**Deps:** T35 · **Parallel:** no
**Files:** `scripts/sign.sh`, `scripts/notarize.sh`, `ClipnestApp/project.yml` (extend: real `DEVELOPMENT_TEAM` / signing identity settings, parameterized not hardcoded — see below)
**Must do:** `sign.sh` runs `codesign --deep --force --options runtime --sign "Developer ID Application: <name> (<TEAMID>)" build/Clipnest.app`, with the identity string passed as a script argument or read from an environment variable — **never hardcoded** in the script or committed anywhere. `notarize.sh` zips the signed app, runs `xcrun notarytool submit <zip> --keychain-profile "<profile-name>" --wait`, then `xcrun stapler staple build/Clipnest.app` on success. The keychain profile (created once, out-of-band, via `xcrun notarytool store-credentials`) is the only credential path — **no Apple ID, app-specific password, or API key ever appears in the repo**, per coding-standards.md's security musts. Document the one-time `store-credentials` setup step in the script's header comment since it's a manual prerequisite the user (who owns the Developer account) must run themselves.
**AC:** Given a valid keychain profile already configured on the signer's machine (not something these scripts can create), `sign.sh` produces a Developer-ID-signed `.app` and `notarize.sh` successfully submits, waits, and staples it. Scripts contain zero embedded credentials — reviewer greps for this explicitly.
**Tests:** devops documents a dry-run (can validate `codesign --verify` and `spctl --assess` output structure even without real notarization if no account is available yet in this environment) and pastes real output; if a live Developer ID isn't available in the build environment, log that limitation explicitly rather than claiming untested success.

### T37 [devops] `create-dmg` packaging + distribution docs
**Deps:** T36 · **Parallel:** no
**Files:** `scripts/package_dmg.sh`, `README.md` (extend — architect's getting-started slice; devops adds the exact packaging command reference here, architect keeps the surrounding prose coherent)
**Must do:** `package_dmg.sh` wraps `create-dmg` (or a manual `hdiutil` fallback if `create-dmg` isn't installed — check for it and give a clear install hint, e.g. `brew install create-dmg`) to produce `Clipnest.dmg` from the stapled `.app`, with a reasonable window layout (drag-to-Applications). Document the full pipeline (`build.sh` → `sign.sh` → `notarize.sh` → `package_dmg.sh`) as a short "Release" section.
**AC:** Running the full script chain against a signed+stapled app produces an installable `.dmg`; `spctl --assess --type open --context context:primary-signature -v Clipnest.dmg` (or `.app`) passes Gatekeeper assessment once actually notarized.
**Tests:** devops pastes real script output; Gatekeeper assessment output specifically, once a real notarized build exists.

### T38 [reviewer] Review Phase E scripts
**Deps:** T35, T36, T37 · **Parallel:** no
**Must do:** Review all four scripts for correctness and, critically, the **mandatory security pass**: grep for any hardcoded Apple ID/password/API key/Team ID string that shouldn't be there, confirm credentials only ever come from the keychain profile or environment variables, confirm entitlements (`ClipnestApp.entitlements`) still contain nothing beyond what's genuinely required (still expected to be the empty/minimal file from T2 unless a real requirement emerged and was logged as a decision).
**AC:** No secrets found in any script or config file; findings resolved.

### T39 [tester] Validate Phase E — full release pipeline + regression
**Deps:** T38, T34 · **Parallel:** no
**Must do:** Run `swift test` one more time (full-project regression, not just Phase E). Run the script chain (or document exactly how far it was possible to get without a live Apple Developer account, per project-context.md's constraint that this is a hard external dependency on the user) and paste real output. Confirm the resulting app/DMG installs and launches on a clean run, menu bar icon appears, and spot-check the picker/paste/settings flows one more time end-to-end as a final regression pass.
**AC:** Evidence pasted for `swift test` (full regression) and for whatever portion of the signing/notarization/DMG pipeline could actually run in this environment, with any gap (e.g. "no Developer ID available here") stated explicitly rather than glossed over. Only after this does the overall Clipnest v1 scope count as `done`.

---

## Summary — task → owner → deps (quick reference; task-board.md is the live status source of truth)

| Phase | Tasks | Gate |
|---|---|---|
| Scaffold | T2 | blocks everything |
| A — Capture | T3, T4, T5, T6, T7 | T8 (reviewer) → T9 (tester) |
| B — Picker & Paste | T10, T11, T12, T13, T14, T15, T16 | T17 (reviewer) → T18 (tester) |
| C — Rich/Pin/Snippets | T19, T20, T21, T22, T23, T24 | T25 (reviewer) → T26 (tester) |
| D — Hotkey/Settings/Privacy/Retention | T27, T28, T29, T30, T31, T32 | T33 (reviewer) → T34 (tester) |
| E — Release | T35, T36, T37 | T38 (reviewer) → T39 (tester) |

**Ready to start now:** T2 only — every other task depends on it directly or transitively.
