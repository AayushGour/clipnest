# Clipnest — Design Spec

**Date:** 2026-08-06
**Status:** Approved (design), pending implementation plan
**Type:** Native macOS clipboard manager

## Background

The user had a free App Store app, `ClipboardManager.app` (dev "abdoo", bundle `com.abdoo.ClipboardManager.clipbord-mac-application`, Team ID `LB6QK2GG48`). It is now **delisted** from the Mac App Store (iTunes lookup by bundle id → `resultCount: 0`) and has **no public source** — it was free but closed-source, distributed via the Mac App Store (the installed copy carries a `_MASReceipt`). There is therefore nothing to fork or rebuild.

Clipnest is a **new, from-scratch** clipboard manager the user owns and will publish. It is not derived from abdoo's binary in any way (no decompilation, no asset reuse) — clipboard managers are a generic app category and this is an independent implementation.

## Goals

- Ship a real, publishable product (not just a personal script).
- Lightest possible footprint on macOS → native Swift/SwiftUI (evaluated against Rust/Tauri/iced and rejected: for a macOS-only menu-bar utility, every OS integration is AppKit, so native is both lighter and simpler; Rust would add FFI weight for no footprint gain).
- Local-only. No accounts, no network, no telemetry.
- Distribute as a notarized direct-download `.dmg`.

## Non-Goals (v1)

- iCloud / cross-device sync
- Auto-update (Sparkle) — deferred to v1.1
- Mac App Store build / sandbox
- Cross-platform (Windows/Linux)
- RTF/styled-paste fidelity beyond plain + basic rich text

## Platform & Toolchain

- **Language/UI:** Swift + SwiftUI, with AppKit where SwiftUI lacks coverage (status item, floating panel, event synthesis).
- **Minimum macOS:** 14.0 (Sonoma). Rationale: SwiftData requires 14; `MenuBarExtra` requires 13; `SMAppService` requires 13 → 14 is the binding constraint and still covers the large majority of Macs.
- **Distribution:** non-sandboxed, Developer ID signed + notarized `.dmg`.
- **One third-party dependency:** `KeyboardShortcuts` (Sindre Sorhus, MIT) for global-hotkey registration + recorder UI. Everything else is system frameworks.

## Architecture

Two modules, so most logic is testable from the CLI without launching a GUI.

### Module 1 — `ClipnestCore` (Swift Package library, no UI)

Fully unit-testable via `swift test`.

- **`Model/`** — value/`@Model` types:
  - `ClipItem { id: UUID, createdAt: Date, kind: ItemKind, previewText: String, contentHash: String, pinned: Bool, sourceAppName: String?, sourceBundleID: String?, byteSize: Int, blobPath: String? }`
  - `Snippet { id: UUID, title: String, body: String, keyword: String?, createdAt: Date }`
  - `ItemKind` enum: `.text, .richText, .link, .image, .file`
- **`Clipboard/`**
  - `ClipboardMonitor` — polls `NSPasteboard.general.changeCount` on a timer (~0.4s; macOS has no push notification for pasteboard changes). On change, hands the pasteboard to `PasteboardReader`.
  - `PasteboardReader` — inspects available types, classifies into `ItemKind`, extracts preview text + payload, computes `contentHash`.
  - `PrivacyFilter` — decides whether a change should be stored (see Privacy).
- **`Store/`**
  - `ClipStore` (protocol) — CRUD, dedup-by-hash, query/search, pin/unpin, delete, clear. Concrete `SwiftDataClipStore` impl.
  - `BlobStore` — large payloads (images, file data) written to `~/Library/Application Support/Clipnest/blobs/<hash>`; DB stores only `blobPath` + metadata, keeping the store lean. Content-addressed by hash → automatic dedup of identical blobs.
- **`Search/`** — `SearchQuery` + filtering (text match over `previewText`, filter by `ItemKind`, scope by tab). Predicate-based over SwiftData for v1; FTS5 is a documented escape hatch if scale demands it.
- **`Paste/`**
  - `FrontmostAppTracker` — records the app that was frontmost before the picker opened, so paste targets the right app.
  - `Paster` — writes chosen content to `NSPasteboard.general`, then synthesizes ⌘V via `CGEvent` to the previously-frontmost app. Event-tap dependency injected so it can be mocked in tests.

### Module 2 — `ClipnestApp` (the `.app` target, SwiftUI + AppKit)

Depends on `ClipnestCore`. Generated with **XcodeGen** (`project.yml` → `.xcodeproj`) so the project is reproducible and buildable/signable from the CLI without hand-editing pbxproj.

- **`App/`** — `@main` app, `MenuBarExtra` (status item + menu), `AppDelegate` wiring, lifecycle, injects `ClipnestCore` services.
- **`UI/Picker/`** — the picker presented in a borderless, **non-activating** `NSPanel` (so the user's current app keeps keyboard focus). SwiftUI content: search field, virtualized item list, tab switcher (History / Pinned / Snippets), type-filter chips, keyboard navigation.
- **`UI/Settings/`** — SwiftUI `Settings` scene: hotkey recorder, launch-at-login toggle, retention/cap, excluded-apps list, privacy toggles, storage usage + "Clear history".
- **`System/`**
  - Hotkey via `KeyboardShortcuts` (default ⌘⇧V).
  - Launch-at-login via `SMAppService.mainApp`.
  - `PermissionsManager` — checks/prompts Accessibility (`AXIsProcessTrusted`), surfaces status in Settings.

## UX / Interaction

- **Menu bar icon** always visible. Left-click opens the picker; right-click → quick menu (Settings, Pause capture, Quit).
- **Global hotkey ⌘⇧V** opens the picker as a floating non-activating panel at the cursor. Focus stays on the underlying app.
- **Picker:**
  - Instant type-to-search (search field auto-focused).
  - Tabs: **History** · **Pinned** · **Snippets** (⌘1 / ⌘2 / ⌘3).
  - Type-filter chips: All / Text / Image / File / Link.
  - Keyboard: ↑/↓ move, **⏎ paste selected**, ⌘F focus search, Esc dismiss. Pin/unpin and delete via row action + shortcut.
- **Settings window** for all configuration listed above.

## Data & Retention

- **Dedup:** consecutive identical copies collapse via `contentHash` (update `createdAt` / move-to-top rather than duplicate).
- **Retention:** default **keep everything** until the user clears it. Pinned items are always exempt from any cleanup. An optional count/time cap is available in Settings (off by default).
- **Storage location:** `~/Library/Application Support/Clipnest/` (SwiftData store + `blobs/`).

## Privacy (first-class)

- Everything stays on-device; no network calls anywhere in the app.
- Honor standard pasteboard privacy markers: skip capture when the pasteboard carries `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType` (password managers set these).
- Auto-exclude known password-manager bundle IDs; user can add more apps to an exclude list in Settings.
- **Pause capture** toggle (menu + Settings).
- "Clear history" wipes DB + blobs.

## Permissions

- **Accessibility** — required **only** for the synthetic-paste step. If not granted, `Paster` falls back to placing the item on the clipboard and the user pastes manually; the app remains fully usable. Reading the pasteboard and registering the global hotkey need no special permission.
- Non-sandboxed direct-download build makes Accessibility + arbitrary disk access straightforward.

## Build, Signing, Distribution

- Build via `xcodebuild` against the XcodeGen-generated project.
- **Sign:** Developer ID Application certificate → `codesign`.
- **Notarize:** `notarytool submit` → `stapler staple`.
- **Package:** `.dmg` (e.g. `create-dmg`).
- ⚠️ **Requires an Apple Developer account ($99/yr)** for the Developer ID cert + notarization — mandatory for direct download, otherwise Gatekeeper blocks the app on other Macs. Local build/run needs no account. This is a hard external dependency on the user, not something code can supply.

## Testing

- `ClipnestCore` unit tests (`swift test`):
  - `PasteboardReader` classification + hashing for each `ItemKind`.
  - Dedup behavior in `ClipStore`.
  - `PrivacyFilter` rejects concealed/transient/excluded sources.
  - `ClipStore` CRUD, pin/unpin, search/filter.
  - `BlobStore` write/read/dedup round-trip.
  - `Paster` with a mocked event synthesizer (no real key events in CI).
- UI kept thin; light smoke tests only.

## Milestones (for the plan to expand)

1. Scaffold: SPM `ClipnestCore` + XcodeGen app target; app launches with a menu bar icon.
2. Capture pipeline: `ClipboardMonitor` + `PasteboardReader` + `PrivacyFilter` + `ClipStore` (text only), tested.
3. Picker UI: panel, list, search, History tab; copy-to-clipboard on select.
4. Paste engine: `FrontmostAppTracker` + `Paster` + Accessibility handling + fallback.
5. Rich kinds: images & files via `BlobStore`; link detection.
6. Pinned + Snippets tabs and their storage.
7. Global hotkey (`KeyboardShortcuts`) + Settings window + launch-at-login.
8. Privacy/exclusions, retention cap, clear-history.
9. Signing + notarization + `.dmg` packaging.

## Implementation Workflow

- **Subagent-driven development**: implement plan tasks via delegated subagents, not inline.
- **Model policy:** subagents run on **Sonnet** by default; Opus only when a task absolutely requires it.
- **Git:** stage finished work with `git add`; **do not commit** — the user authors commits.
