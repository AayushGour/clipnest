# Clipnest Settings window — design (2026-08-14)

> Status: **fully specified.** Surface, scope, and all UX decisions locked. The
> two previously-open questions are resolved (retention cadence = on-launch +
> after-each-capture; History is its own sub-tab). Ready for `writing-plans`.

## Decisions locked
- **Surface:** a separate macOS **Settings window** (SwiftUI `Settings` scene),
  opened via **⌘,** and a **Settings…** item in the menu-bar menu (`SettingsLink`,
  macOS 14+). NOT a 4th tab in the picker.
- **Scope (all four):** General (launch-at-login, pause, clear history),
  Retention cap, rebind global shortcuts (⌥⌘V/⌥⌘E), excluded-apps list.
- **Retention UX:** mode picker — Unlimited / N items / N days — mapping directly
  to `RetentionCap?` (`nil` / `.maxCount` / `.maxAge`). Default **1,000 items**.
  Pinned always kept. Enforced on launch + after each capture.
- **Excluded-apps add:** "Add…" → `NSOpenPanel` scoped to `.app` bundles, read
  the bundle ID from the chosen app.

## Design

### 1. Surface & entry points
- New SwiftUI `Settings` scene → standard Settings window (⌘,).
- Menu-bar menu grows to: **Open Clipnest** · **Pause capture** (checkmark toggle)
  · **Settings…** · **Quit**.
- `SettingsView` = `TabView` with sub-tabs: **General · History · Shortcuts · Apps**.

### 2. Persistence — one `SettingsStore`
- Single `@Observable @MainActor SettingsStore` backed by `UserDefaults` through
  ONE typed keys enum (coding-standards "config in one place" — no scattered
  `@AppStorage`). Lives in `ClipnestApp/Sources/System/`.
- Holds: `launchAtLogin: Bool`, `isCaptureEnabled: Bool`, `retentionMode`
  (unlimited/items/days) + `retentionCount: Int` + `retentionDays: Int`,
  `userExcludedBundleIDs: [String]`.
- Exposes computed `retentionCap: RetentionCap?` to hand to Core.
- **Hotkeys are NOT stored here** — the `KeyboardShortcuts` library persists +
  re-registers them itself.

### 3. The four tabs
- **General** — Launch at login (→ `SMAppService.mainApp`), Pause capture
  (→ `isCaptureEnabled`).
- **History** — retention mode picker + value field (default 1,000 items,
  pinned always kept); **Clear all history…** (confirm alert → `clipStore.clearHistory()`).
- **Shortcuts** — two `KeyboardShortcuts.Recorder`s (⌥⌘V picker, ⌥⌘E expand);
  library auto-persists + re-registers.
- **Apps** — excluded list; built-in password managers shown **locked**
  (unremovable), user apps removable; **Add…** → `NSOpenPanel` → bundle ID.

### 4. Wiring into Core (via `AppEnvironment`)
- **Excluded apps:** `excludedBundleIDsProvider` reads
  `settingsStore.userExcludedBundleIDs`. Concealed/transient + built-in
  password-manager rules stay enforced INSIDE `PrivacyFilter`, unremovable.
- **Pause — correctness note:** `ClipboardMonitor.pause()/resume()` are already
  used for *transient* self-write suppression during snippet expansion. The user
  pause MUST be a separate, persisted gate (e.g. a `captureEnabledProvider`
  checked in `checkNow()`), orthogonal to the transient pause — otherwise a
  clipboard-borrow `resume()` would silently un-pause the user.
- **Retention:** `AppEnvironment` calls
  `clipStore.enforceRetention(cap: settingsStore.retentionCap)` on launch and
  after each capture (bounded delete; pinned protected). Wires the deferred
  unbounded-growth finding.
- **Launch-at-login:** small `LaunchAtLoginController` wrapping `SMAppService`.

### 5. Errors & testing
- `SMAppService` register/clear-history can throw → inline error + revert toggle,
  never crash. Typed errors where Core is touched.
- **Tests:** Core — the new capture-enabled gate (paused→no capture,
  enabled→captures). App (`ClipnestAppTests`) — `SettingsStore` pure logic:
  `retentionCap` derivation, exclude add/remove/dedupe-vs-builtins, pause flag.
  System boundaries (SMAppService, NSOpenPanel, Recorder) are manual-only.

### Out of scope (YAGNI)
No import/export, no sync, no Accessibility-permission UI (capture works without it).

## Resolved decisions (were open)
1. **Retention cadence:** enforce on launch + after each capture. Bounded DELETE,
   pinned protected — cheap even at 10k rows; no timer, no staleness window.
2. **History tab:** its own sub-tab (retention picker + Clear-all), NOT folded
   into General. Four tabs total: General · History · Shortcuts · Apps.
