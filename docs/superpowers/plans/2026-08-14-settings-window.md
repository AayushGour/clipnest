# Clipnest Settings Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native macOS Settings window (⌘,) to Clipnest with four tabs — General, History, Shortcuts, Apps — that let the user pause capture, cap history retention, rebind the global shortcuts, and exclude apps from capture.

**Architecture:** A single `@Observable @MainActor SettingsStore` (UserDefaults-backed, one typed keys enum) is the source of truth for capture-enabled / retention / excluded-apps, created in `AppEnvironment` and read by both the SwiftUI Settings views and the `ClipboardMonitor` (via provider closures already on its initializer). Launch-at-login is delegated to `SMAppService` through a thin `LaunchAtLoginController`; the two global shortcuts reuse the already-defined `KeyboardShortcuts.Name` values via the library's `Recorder`. Retention is enforced on launch and after each capture by calling the existing `ClipStore.enforceRetention(cap:)`.

**Tech Stack:** Swift 6, SwiftUI (`Settings` scene, `Form`, `TabView`), SwiftData (via existing `ClipStore`), `ServiceManagement.SMAppService`, `KeyboardShortcuts` (Sindre Sorhus), Swift Testing, XcodeGen.

## Global Constraints

- **Never `git commit` / `git push`.** Each task ends by *staging* finished files with `git add`; the user commits. (Persistent project rule.)
- **Local-only, always:** no `URLSession`, sockets, or any network code anywhere. Nothing in this feature makes a network call.
- **Privacy invariant is unbypassable:** built-in password-manager bundle IDs and the concealed/transient markers stay enforced *inside* `PrivacyFilter`. The Settings excluded-apps list can only ever *add* exclusions, never remove built-ins.
- **User pause is orthogonal to transient pause:** `ClipboardMonitor.pause()/resume()` are already used for self-write suppression during snippet expansion. The user's Pause must be a *separate* persisted gate, never the same flag — otherwise a clipboard-borrow `resume()` would silently un-pause the user.
- **Swift 6 strict concurrency:** `SettingsStore` is `@MainActor`; the monitor's `@Sendable` provider closures read it via `MainActor.assumeIsolated { … }` (safe — `checkNow()` is `@MainActor`).
- **Retention default is 1,000 items.** Pinned items are always kept regardless of cap (already guaranteed by `enforceRetention`).
- **New Swift files are auto-included** by XcodeGen's recursive `sources:` globs — run `xcodegen generate` from `ClipnestApp/` after creating files, before building.
- **Test framework is Swift Testing** (`@Suite`/`@Test`/`#expect`), never XCTest. App tests use `@testable import Clipnest` (module name is `Clipnest`, not `ClipnestApp`).
- **Out of scope (YAGNI):** no import/export, no sync, no Accessibility-permission UI.

**Build/test commands:**
- Core library + its tests: `swift build` and `swift test` from the repo root.
- App target: `cd ClipnestApp && xcodegen generate && xcodebuild -scheme ClipnestApp -destination 'platform=macOS' build` (append `test` instead of `build` to run `ClipnestAppTests`).

---

### Task 1: Core — add a `captureEnabledProvider` gate to `ClipboardMonitor`

The user's Pause needs its own persisted gate, read fresh every cycle, kept separate from the transient `isPaused` flag (Global Constraints). Add a provider closure to the monitor and fold it into the existing `PrivacyFilter.shouldCapture` call.

**Files:**
- Modify: `Sources/ClipnestCore/Clipboard/ClipboardMonitor.swift`
- Test: `Tests/ClipnestCoreTests/ClipboardMonitorTests.swift`

**Interfaces:**
- Consumes: existing `PrivacyFilter.shouldCapture(availableTypes:sourceBundleID:isPaused:customExcludedBundleIDs:)`.
- Produces: `ClipboardMonitor.init(…, captureEnabledProvider: @escaping @Sendable () -> Bool = { true }, …)` — a new initializer parameter (defaulted, so all existing call sites keep compiling). When it returns `false`, `checkNow()` captures nothing.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ClipnestCoreTests/ClipboardMonitorTests.swift`, inside the existing `struct ClipboardMonitorTests` (mirroring the existing `pausedMonitorCapturesNothing` / `resumeReenablesCapture` tests):

```swift
  @Test("captureEnabledProvider == false suppresses capture even on a real change")
  func captureDisabledProviderSuppressesCapture() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(
      store: store,
      pasteboard: pasteboard,
      captureEnabledProvider: { false }
    )

    pasteboard.simulateCopy(text: "should not be captured")
    let result = await monitor.checkNow()

    #expect(result == nil)
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  @Test("captureEnabledProvider is read fresh each cycle — flipping it to true re-enables capture")
  func captureEnabledProviderReadFreshEachCycle() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    var enabled = false
    let monitor = ClipboardMonitor(
      store: store,
      pasteboard: pasteboard,
      captureEnabledProvider: { enabled }
    )

    pasteboard.simulateCopy(text: "while disabled")
    #expect(await monitor.checkNow() == nil)

    enabled = true
    pasteboard.simulateCopy(text: "after enabling")
    let result = await monitor.checkNow()

    #expect(result?.previewText == "after enabling")
    let all = try await store.fetchAll()
    #expect(all.count == 1)
  }

  @Test("transient resume() does not override a disabled captureEnabledProvider")
  func transientResumeDoesNotOverrideUserPause() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(
      store: store,
      pasteboard: pasteboard,
      captureEnabledProvider: { false }  // user pause is ON
    )

    // Simulate the snippet-expansion clipboard borrow: transient pause then resume.
    monitor.pause()
    monitor.resume()

    pasteboard.simulateCopy(text: "still should not capture")
    let result = await monitor.checkNow()

    #expect(result == nil)
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClipboardMonitorTests`
Expected: compile failure — `extra argument 'captureEnabledProvider' in call`.

- [ ] **Step 3: Add the parameter and fold it into the capture decision**

In `Sources/ClipnestCore/Clipboard/ClipboardMonitor.swift`:

Add a stored property alongside `excludedBundleIDsProvider` (near line 92):

```swift
  private let excludedBundleIDsProvider: @Sendable () -> Set<String>
  /// Returns whether the *user* currently wants capture on (the persisted
  /// Settings "Pause capture" gate). Read fresh every `checkNow()` cycle and
  /// kept deliberately separate from the transient `isPaused` flag (which the
  /// snippet-expansion clipboard borrow toggles) — a transient `resume()` must
  /// never silently un-pause a user who paused in Settings. Defaults to always
  /// enabled so isolated tests and existing call sites need no change.
  private let captureEnabledProvider: @Sendable () -> Bool
```

Add the init parameter (after `excludedBundleIDsProvider`, before `captureFailureHandler`, near line 132):

```swift
    excludedBundleIDsProvider: @escaping @Sendable () -> Set<String> = { [] },
    captureEnabledProvider: @escaping @Sendable () -> Bool = { true },
    captureFailureHandler: @escaping CaptureFailureHandler = ClipboardMonitor.logCaptureFailure
```

Assign it in the initializer body (after the `excludedBundleIDsProvider` assignment, near line 142):

```swift
    self.excludedBundleIDsProvider = excludedBundleIDsProvider
    self.captureEnabledProvider = captureEnabledProvider
```

Fold it into the `shouldCapture` call inside `checkNow()` (near line 215) — change only the `isPaused:` argument:

```swift
    guard
      privacyFilter.shouldCapture(
        availableTypes: pasteboard.availableTypes,
        sourceBundleID: sourceBundleID,
        isPaused: isPaused || !captureEnabledProvider(),
        customExcludedBundleIDs: excludedBundleIDsProvider()
      )
    else {
      return nil
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClipboardMonitorTests`
Expected: PASS (all existing monitor tests plus the three new ones).

- [ ] **Step 5: Stage**

```bash
git add Sources/ClipnestCore/Clipboard/ClipboardMonitor.swift Tests/ClipnestCoreTests/ClipboardMonitorTests.swift
```

---

### Task 2: App — `SettingsStore` (persisted, observable, pure logic)

The single source of truth for capture-enabled, retention, and user-excluded apps. All the testable logic of this feature lives here.

**Files:**
- Create: `ClipnestApp/Sources/System/SettingsStore.swift`
- Test: `ClipnestApp/Tests/ClipnestAppTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `RetentionCap` and `PrivacyFilter.builtInExcludedBundleIDs` from `ClipnestCore`.
- Produces:
  - `@MainActor @Observable final class SettingsStore` with `init(defaults: UserDefaults = .standard)`.
  - `enum SettingsStore.RetentionMode: String, CaseIterable, Sendable { case unlimited, items, days }`.
  - Observable stored vars: `isCaptureEnabled: Bool`, `retentionMode: RetentionMode`, `retentionItemCount: Int`, `retentionDays: Int`, `private(set) userExcludedBundleIDs: [String]`.
  - `var retentionCap: RetentionCap?` (computed).
  - `func addExcludedApp(bundleID: String)`, `func removeExcludedApp(bundleID: String)`.
  - `static let defaultItemCount = 1000`, `static let defaultDays = 30`.

- [ ] **Step 1: Write the failing tests**

Create `ClipnestApp/Tests/ClipnestAppTests/SettingsStoreTests.swift`:

```swift
// SettingsStoreTests.swift
//
// Pure logic of the Settings feature: retentionCap derivation, excluded-app
// add/remove/dedup-vs-builtins, and UserDefaults persistence across instances.
// The SwiftUI views and the SMAppService / NSOpenPanel / KeyboardShortcuts
// system boundaries are manual-only (see the plan).

import ClipnestCore
import Foundation
import Testing

@testable import Clipnest

@MainActor
@Suite("SettingsStore")
struct SettingsStoreTests {

  /// A throwaway, isolated UserDefaults suite so tests never touch the real
  /// app domain or each other. (UUID is available in the test runtime.)
  private func makeDefaults() -> UserDefaults {
    let name = "SettingsStoreTests-\(UUID().uuidString)"
    return UserDefaults(suiteName: name)!
  }

  @Test("defaults: capture on, 1000 items, cap == .maxCount(1000)")
  func sensibleDefaults() {
    let store = SettingsStore(defaults: makeDefaults())
    #expect(store.isCaptureEnabled == true)
    #expect(store.retentionMode == .items)
    #expect(store.retentionItemCount == 1000)
    #expect(store.retentionCap == .maxCount(1000))
  }

  @Test("retentionCap: unlimited -> nil")
  func unlimitedCapIsNil() {
    let store = SettingsStore(defaults: makeDefaults())
    store.retentionMode = .unlimited
    #expect(store.retentionCap == nil)
  }

  @Test("retentionCap: days -> maxAge in seconds")
  func daysCapIsSeconds() {
    let store = SettingsStore(defaults: makeDefaults())
    store.retentionMode = .days
    store.retentionDays = 7
    #expect(store.retentionCap == .maxAge(7 * 86_400))
  }

  @Test("retentionCap: item count is clamped to at least 1")
  func itemCountClampedToOne() {
    let store = SettingsStore(defaults: makeDefaults())
    store.retentionMode = .items
    store.retentionItemCount = 0
    #expect(store.retentionCap == .maxCount(1))
  }

  @Test("addExcludedApp appends a new bundle ID")
  func addExcludedApp() {
    let store = SettingsStore(defaults: makeDefaults())
    store.addExcludedApp(bundleID: "com.example.notes")
    #expect(store.userExcludedBundleIDs == ["com.example.notes"])
  }

  @Test("addExcludedApp ignores duplicates and blanks")
  func addExcludedAppDedupes() {
    let store = SettingsStore(defaults: makeDefaults())
    store.addExcludedApp(bundleID: "com.example.notes")
    store.addExcludedApp(bundleID: "com.example.notes")
    store.addExcludedApp(bundleID: "   ")
    #expect(store.userExcludedBundleIDs == ["com.example.notes"])
  }

  @Test("addExcludedApp never stores a built-in — it's already enforced in PrivacyFilter")
  func addExcludedAppSkipsBuiltIns() {
    let store = SettingsStore(defaults: makeDefaults())
    let builtIn = PrivacyFilter.builtInExcludedBundleIDs.first!
    store.addExcludedApp(bundleID: builtIn)
    #expect(store.userExcludedBundleIDs.isEmpty)
  }

  @Test("removeExcludedApp removes the given bundle ID")
  func removeExcludedApp() {
    let store = SettingsStore(defaults: makeDefaults())
    store.addExcludedApp(bundleID: "com.a")
    store.addExcludedApp(bundleID: "com.b")
    store.removeExcludedApp(bundleID: "com.a")
    #expect(store.userExcludedBundleIDs == ["com.b"])
  }

  @Test("state persists across instances sharing the same UserDefaults")
  func persistsAcrossInstances() {
    let defaults = makeDefaults()
    let first = SettingsStore(defaults: defaults)
    first.isCaptureEnabled = false
    first.retentionMode = .days
    first.retentionDays = 14
    first.addExcludedApp(bundleID: "com.example.secret")

    let second = SettingsStore(defaults: defaults)
    #expect(second.isCaptureEnabled == false)
    #expect(second.retentionMode == .days)
    #expect(second.retentionDays == 14)
    #expect(second.userExcludedBundleIDs == ["com.example.secret"])
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -scheme ClipnestApp -destination 'platform=macOS' test`
Expected: compile failure — `cannot find 'SettingsStore' in scope`.

- [ ] **Step 3: Create `SettingsStore`**

Create `ClipnestApp/Sources/System/SettingsStore.swift`:

```swift
// SettingsStore.swift
//
// The single source of truth for Clipnest's user-configurable behavior:
// capture on/off, history retention, and user-excluded apps. Backed by
// `UserDefaults` through ONE typed key list (coding-standards "config in one
// place" — no scattered `@AppStorage`). `@Observable` so SwiftUI Settings
// views bind directly; `@MainActor` because it drives UI. Read by the
// `ClipboardMonitor`'s provider closures via `MainActor.assumeIsolated`
// (see AppEnvironment).
//
// NOT stored here: the two global shortcuts (the KeyboardShortcuts library
// persists + re-registers those itself) and launch-at-login (SMAppService is
// its own persistent source of truth — see LaunchAtLoginController).

import ClipnestCore
import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
  /// How history retention is capped. Maps 1:1 to `RetentionCap?`.
  enum RetentionMode: String, CaseIterable, Sendable {
    case unlimited
    case items
    case days
  }

  static let defaultItemCount = 1000
  static let defaultDays = 30

  private enum Key {
    static let isCaptureEnabled = "settings.isCaptureEnabled"
    static let retentionMode = "settings.retentionMode"
    static let retentionItemCount = "settings.retentionItemCount"
    static let retentionDays = "settings.retentionDays"
    static let userExcludedBundleIDs = "settings.userExcludedBundleIDs"
  }

  // `@ObservationIgnored`: the backing store is not observable UI state.
  @ObservationIgnored private let defaults: UserDefaults

  var isCaptureEnabled: Bool {
    didSet { defaults.set(isCaptureEnabled, forKey: Key.isCaptureEnabled) }
  }
  var retentionMode: RetentionMode {
    didSet { defaults.set(retentionMode.rawValue, forKey: Key.retentionMode) }
  }
  var retentionItemCount: Int {
    didSet { defaults.set(retentionItemCount, forKey: Key.retentionItemCount) }
  }
  var retentionDays: Int {
    didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
  }
  private(set) var userExcludedBundleIDs: [String] {
    didSet { defaults.set(userExcludedBundleIDs, forKey: Key.userExcludedBundleIDs) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // `object(forKey:) as? Bool` distinguishes "absent" (-> default true)
    // from an explicitly-stored false — `bool(forKey:)` can't.
    self.isCaptureEnabled = defaults.object(forKey: Key.isCaptureEnabled) as? Bool ?? true
    self.retentionMode =
      defaults.string(forKey: Key.retentionMode).flatMap(RetentionMode.init(rawValue:)) ?? .items
    self.retentionItemCount =
      defaults.object(forKey: Key.retentionItemCount) as? Int ?? Self.defaultItemCount
    self.retentionDays = defaults.object(forKey: Key.retentionDays) as? Int ?? Self.defaultDays
    self.userExcludedBundleIDs = defaults.stringArray(forKey: Key.userExcludedBundleIDs) ?? []
  }

  /// The cap handed to `ClipStore.enforceRetention(cap:)`. Values are clamped
  /// to at least 1 so a stray 0 can never mean "delete everything."
  var retentionCap: RetentionCap? {
    switch retentionMode {
    case .unlimited: return nil
    case .items: return .maxCount(max(1, retentionItemCount))
    case .days: return .maxAge(TimeInterval(max(1, retentionDays)) * 86_400)
    }
  }

  /// Adds a user exclusion. No-ops on blanks, duplicates, and built-in
  /// password-manager IDs (those are always enforced inside `PrivacyFilter`,
  /// so storing them here would be a meaningless duplicate).
  func addExcludedApp(bundleID: String) {
    let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard !PrivacyFilter.builtInExcludedBundleIDs.contains(trimmed) else { return }
    guard !userExcludedBundleIDs.contains(trimmed) else { return }
    userExcludedBundleIDs.append(trimmed)
  }

  func removeExcludedApp(bundleID: String) {
    userExcludedBundleIDs.removeAll { $0 == bundleID }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ClipnestApp && xcodebuild -scheme ClipnestApp -destination 'platform=macOS' test`
Expected: PASS (9 new `SettingsStore` tests, existing tests unaffected).

- [ ] **Step 5: Stage**

```bash
git add ClipnestApp/Sources/System/SettingsStore.swift ClipnestApp/Tests/ClipnestAppTests/SettingsStoreTests.swift
```

---

### Task 3: App — `LaunchAtLoginController` (SMAppService wrapper)

A thin wrapper so the General tab can toggle launch-at-login without embedding `SMAppService` calls in the view. `SMAppService` is a system boundary with no fake, so this task is verified by a build + a documented manual smoke (same precedent as `HotkeyManager`, which has no unit test).

**Files:**
- Create: `ClipnestApp/Sources/System/LaunchAtLoginController.swift`

**Interfaces:**
- Produces:
  - `enum LaunchAtLoginController` with `@MainActor static var isEnabled: Bool { get }` and `@MainActor static func setEnabled(_ enabled: Bool) throws`.

- [ ] **Step 1: Create the controller**

Create `ClipnestApp/Sources/System/LaunchAtLoginController.swift`:

```swift
// LaunchAtLoginController.swift
//
// Wraps `SMAppService.mainApp` so the General settings tab can toggle
// launch-at-login without embedding ServiceManagement calls in the view.
// `SMAppService` is itself the persistent source of truth across launches —
// so there is deliberately no mirrored `Bool` in `SettingsStore`; `isEnabled`
// always reflects the system's real registration state, avoiding drift.
//
// This is a pure system boundary (no fake exists), so it has no unit test —
// verified by launching the app and toggling the switch (see the plan).

import ServiceManagement

@MainActor
enum LaunchAtLoginController {
  /// Whether Clipnest is currently registered to launch at login.
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// Registers or unregisters Clipnest as a login item.
  /// - Throws: whatever `SMAppService.register()/unregister()` throws (e.g. the
  ///   app isn't in a location macOS will register, or the user denied it) —
  ///   surfaced so the caller can show an inline error and revert the toggle.
  static func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}
```

- [ ] **Step 2: Verify it builds**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -scheme ClipnestApp -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. (Manual toggle smoke happens in Task 5, once the General tab exists.)

- [ ] **Step 3: Stage**

```bash
git add ClipnestApp/Sources/System/LaunchAtLoginController.swift
```

---

### Task 4: App — wire `SettingsStore` + providers + retention into the composition root

Create the one `SettingsStore`, feed its excluded-apps + capture-enabled state into the `ClipboardMonitor`, enforce retention on launch and after each capture, and expose the store for the Settings views. This connects the pieces tested in Tasks 1–2; the wiring itself is verified by build + the Task 5 manual smoke.

**Files:**
- Modify: `ClipnestApp/Sources/App/AppEnvironment.swift`
- Modify: `ClipnestApp/Sources/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `SettingsStore` (Task 2), `ClipboardMonitor.init(…, excludedBundleIDsProvider:, captureEnabledProvider:, …)` (Task 1 + existing).
- Produces:
  - `AppEnvironment.settingsStore: SettingsStore` (stored, exposed).
  - `AppEnvironment.enforceRetentionNow()` — fire-and-forget retention pass, called at launch and reusable.

- [ ] **Step 1: Add the store, providers, retention, and logger to `AppEnvironment`**

In `ClipnestApp/Sources/App/AppEnvironment.swift`:

Add `import os` near the top imports (after `import Foundation`):

```swift
import Foundation
import os
```

Add the stored property to the property list (after `let privacyFilter: PrivacyFilter`, near line 58):

```swift
  let settingsStore: SettingsStore
```

Add a logger as a static member of the class (just inside `final class AppEnvironment {`, before `let blobStore`):

```swift
  private static let logger = Logger(subsystem: ClipnestLog.subsystem, category: "AppEnvironment")
```

In `init()`, create the store right after `privacyFilter` is made (near line 79) and assign it with the other stored-property assignments:

```swift
    let privacyFilter = PrivacyFilter()
    let settingsStore = SettingsStore()
```

Assign it alongside the existing `self.` assignments (after `self.privacyFilter = privacyFilter`, near line 85):

```swift
    self.privacyFilter = privacyFilter
    self.settingsStore = settingsStore
```

Replace the `ClipboardMonitor` construction (near lines 105–110) to pass the two providers. `settingsStore` is a `@MainActor` class (implicitly `Sendable`); the `@Sendable` closures read its `@MainActor` state via `MainActor.assumeIsolated`, which is safe because `checkNow()` runs on the main actor:

```swift
    self.clipboardMonitor = ClipboardMonitor(
      store: clipStore,
      privacyFilter: privacyFilter,
      reader: pasteboardReader,
      blobStore: blobStore,
      excludedBundleIDsProvider: {
        MainActor.assumeIsolated { Set(settingsStore.userExcludedBundleIDs) }
      },
      captureEnabledProvider: {
        MainActor.assumeIsolated { settingsStore.isCaptureEnabled }
      }
    )
```

Extend the existing `monitor.onCapture` closure (near line 240) to also enforce retention after each capture. Replace it with:

```swift
    let retentionStore = clipStore
    monitor.onCapture = { [weak viewModel] _ in
      viewModel?.handleNewCapture()
      let cap = settingsStore.retentionCap
      Task {
        do {
          try await retentionStore.enforceRetention(cap: cap)
        } catch {
          Self.logger.error("retention enforcement failed after capture: \(String(describing: error))")
        }
      }
    }
```

Add the `enforceRetentionNow()` method after `showPicker()` (near line 287, before the closing brace of the class):

```swift
  /// Trims history down to the user's configured cap once, now — called at
  /// launch (also runs after each capture via `onCapture`). Fire-and-forget;
  /// a failure is logged (metadata only), never surfaced, since retention is
  /// best-effort housekeeping, not a user action. Pinned items are always
  /// kept (guaranteed by `enforceRetention`).
  func enforceRetentionNow() {
    let cap = settingsStore.retentionCap
    let retentionStore = clipStore
    Task {
      do {
        try await retentionStore.enforceRetention(cap: cap)
      } catch {
        Self.logger.error("retention enforcement failed at launch: \(String(describing: error))")
      }
    }
  }
```

- [ ] **Step 2: Call retention enforcement at launch**

In `ClipnestApp/Sources/App/AppDelegate.swift`, in `applicationDidFinishLaunching`, add the enforcement call right after `environment.registerHotkey()` (near line 30):

```swift
      environment.startCapture()
      environment.registerHotkey()
      environment.enforceRetentionNow()
```

- [ ] **Step 3: Verify it builds**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -scheme ClipnestApp -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED with no Swift 6 concurrency errors.

- [ ] **Step 4: Run the full test suites (nothing should regress)**

Run: `swift test && cd ClipnestApp && xcodebuild -scheme ClipnestApp -destination 'platform=macOS' test`
Expected: PASS.

- [ ] **Step 5: Stage**

```bash
git add ClipnestApp/Sources/App/AppEnvironment.swift ClipnestApp/Sources/App/AppDelegate.swift
```

---

### Task 5: App — Settings scene + `SettingsView` shell + General tab + menu entry points

Make Settings openable end-to-end: a ⌘, Settings window with a working General tab (launch-at-login + pause), plus the menu-bar "Pause Capture" toggle and "Settings…" item. This is the first user-visible milestone. SwiftUI views have no unit tests (their logic lives in the already-tested `SettingsStore`); verification is build + a specific manual smoke.

**Files:**
- Create: `ClipnestApp/Sources/UI/Settings/SettingsView.swift`
- Create: `ClipnestApp/Sources/UI/Settings/GeneralSettingsView.swift`
- Modify: `ClipnestApp/Sources/App/ClipnestApp.swift`

**Interfaces:**
- Consumes: `AppEnvironment.settingsStore`, `AppEnvironment.clipStore`, `LaunchAtLoginController`.
- Produces:
  - `struct SettingsView: View` with `init(settings: SettingsStore, clipStore: any ClipStore)` — a `TabView` shell. In this task only the **General** tab is populated; History/Shortcuts/Apps tabs are added in Tasks 6–8. To keep every task's build green, add all four tab items now but point History/Shortcuts/Apps at a shared `ComingSoonPlaceholder` inline view, replaced in later tasks.
  - `struct GeneralSettingsView: View` with `init(settings: SettingsStore)`.

- [ ] **Step 1: Create `GeneralSettingsView`**

Create `ClipnestApp/Sources/UI/Settings/GeneralSettingsView.swift`:

```swift
// GeneralSettingsView.swift
//
// The General settings tab: launch-at-login (via LaunchAtLoginController /
// SMAppService) and the user Pause toggle (via SettingsStore.isCaptureEnabled,
// the persisted gate the ClipboardMonitor reads every cycle). A failed
// launch-at-login change shows an inline error and reverts the switch —
// never crashes (SMAppService can throw).

import SwiftUI

struct GeneralSettingsView: View {
  @Bindable var settings: SettingsStore

  @State private var launchAtLogin = LaunchAtLoginController.isEnabled
  @State private var launchError: String?

  init(settings: SettingsStore) {
    self.settings = settings
  }

  var body: some View {
    Form {
      Toggle("Launch Clipnest at login", isOn: $launchAtLogin)
        .onChange(of: launchAtLogin) { _, newValue in
          do {
            try LaunchAtLoginController.setEnabled(newValue)
            launchError = nil
          } catch {
            launchError = error.localizedDescription
            // Revert to the system's real state so the switch never lies.
            launchAtLogin = LaunchAtLoginController.isEnabled
          }
        }
      if let launchError {
        Text(launchError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Toggle(
        "Pause clipboard capture",
        isOn: Binding(
          get: { !settings.isCaptureEnabled },
          set: { settings.isCaptureEnabled = !$0 }
        )
      )
      Text("While paused, Clipnest ignores everything you copy.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
  }
}
```

- [ ] **Step 2: Create `SettingsView` shell**

Create `ClipnestApp/Sources/UI/Settings/SettingsView.swift`:

```swift
// SettingsView.swift
//
// The Settings window body: a TabView with General / History / Shortcuts /
// Apps. Dependencies are injected from AppEnvironment (via ClipnestApp's
// `Settings` scene) — this view owns no state itself; all persisted state
// lives in the injected SettingsStore.

import ClipnestCore
import SwiftUI

struct SettingsView: View {
  private let settings: SettingsStore
  private let clipStore: any ClipStore

  init(settings: SettingsStore, clipStore: any ClipStore) {
    self.settings = settings
    self.clipStore = clipStore
  }

  var body: some View {
    TabView {
      GeneralSettingsView(settings: settings)
        .tabItem { Label("General", systemImage: "gearshape") }

      HistorySettingsView(settings: settings, clipStore: clipStore)
        .tabItem { Label("History", systemImage: "clock") }

      ShortcutsSettingsView()
        .tabItem { Label("Shortcuts", systemImage: "command") }

      AppsSettingsView(settings: settings)
        .tabItem { Label("Apps", systemImage: "app.badge") }
    }
    .frame(width: 460, height: 340)
  }
}
```

Because Tasks 6–8 create `HistorySettingsView` / `ShortcutsSettingsView` / `AppsSettingsView`, add temporary stubs so this task compiles on its own. Create them as **separate files** (they will be *overwritten* — not appended to — by the later tasks, so no leftover placeholder survives):

`ClipnestApp/Sources/UI/Settings/HistorySettingsView.swift`:

```swift
import ClipnestCore
import SwiftUI

// Stub — replaced in Task 6.
struct HistorySettingsView: View {
  let settings: SettingsStore
  let clipStore: any ClipStore
  var body: some View {
    Text("History").foregroundStyle(.secondary)
  }
}
```

`ClipnestApp/Sources/UI/Settings/ShortcutsSettingsView.swift`:

```swift
import SwiftUI

// Stub — replaced in Task 7.
struct ShortcutsSettingsView: View {
  var body: some View {
    Text("Shortcuts").foregroundStyle(.secondary)
  }
}
```

`ClipnestApp/Sources/UI/Settings/AppsSettingsView.swift`:

```swift
import SwiftUI

// Stub — replaced in Task 8.
struct AppsSettingsView: View {
  let settings: SettingsStore
  var body: some View {
    Text("Apps").foregroundStyle(.secondary)
  }
}
```

- [ ] **Step 3: Add the `Settings` scene and menu entry points to `ClipnestApp`**

Replace the body of `ClipnestApp/Sources/App/ClipnestApp.swift` with:

```swift
// ClipnestApp.swift
//
// App entry point. Declares the menu-bar presence (MenuBarExtra) — Clipnest's
// only always-visible surface (no Dock icon, no main window) — and the
// Settings scene (⌘, / "Settings…"). Settings dependencies come from the one
// AppEnvironment the AppDelegate builds at launch; the `if let` fallback only
// ever shows before launch finishes, which is before any window can open.

import SwiftUI

@main
struct ClipnestApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      Button("Open Clipnest") {
        appDelegate.showPicker()
      }
      Divider()
      if let settings = appDelegate.environment?.settingsStore {
        Toggle(
          "Pause Capture",
          isOn: Binding(
            get: { !settings.isCaptureEnabled },
            set: { settings.isCaptureEnabled = !$0 }
          )
        )
      }
      SettingsLink {
        Text("Settings…")
      }
      Divider()
      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
    } label: {
      Image("MenuBarIcon")
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 18, height: 18)
    }
    .menuBarExtraStyle(.menu)

    Settings {
      if let environment = appDelegate.environment {
        SettingsView(settings: environment.settingsStore, clipStore: environment.clipStore)
      } else {
        Text("Starting Clipnest…")
          .frame(width: 460, height: 340)
      }
    }
  }
}
```

- [ ] **Step 4: Verify it builds**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -scheme ClipnestApp -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual smoke (system boundaries have no automated test)**

Build & launch the app (`open` the built `.app`, or run from Xcode). Verify:
1. Menu bar → "Settings…" opens a window titled Clipnest with four tabs; General is selected.
2. Toggle **Pause clipboard capture** on → copy some text elsewhere → open the picker (⌥⌘V): the copy was NOT captured. Toggle off → copy again → it IS captured.
3. The menu-bar **Pause Capture** item shows the same state (checkmark when paused) and toggles the same gate.
4. Toggle **Launch Clipnest at login** on, then off; no crash. (Optionally confirm in System Settings → General → Login Items.)

- [ ] **Step 6: Stage**

```bash
git add ClipnestApp/Sources/UI/Settings/SettingsView.swift \
        ClipnestApp/Sources/UI/Settings/GeneralSettingsView.swift \
        ClipnestApp/Sources/UI/Settings/HistorySettingsView.swift \
        ClipnestApp/Sources/UI/Settings/ShortcutsSettingsView.swift \
        ClipnestApp/Sources/UI/Settings/AppsSettingsView.swift \
        ClipnestApp/Sources/App/ClipnestApp.swift
```

---

### Task 6: App — History tab (retention picker + Clear All History)

Replace the History stub with the real retention controls and a confirming Clear-All. All derivation logic (`retentionCap`, clamping) is already unit-tested in Task 2; this view just binds to it.

**Files:**
- Modify (overwrite the stub): `ClipnestApp/Sources/UI/Settings/HistorySettingsView.swift`

**Interfaces:**
- Consumes: `SettingsStore.retentionMode/retentionItemCount/retentionDays`, `ClipStore.clearHistory()`.

- [ ] **Step 1: Overwrite `HistorySettingsView.swift` with the real tab**

```swift
// HistorySettingsView.swift
//
// The History settings tab: choose how much history to keep (maps directly to
// SettingsStore.retentionCap -> ClipStore.enforceRetention) and clear it all.
// Pinned items are always kept, regardless of the cap. Retention derivation is
// unit-tested in SettingsStoreTests; this view is pure binding + a confirm.

import ClipnestCore
import SwiftUI

struct HistorySettingsView: View {
  @Bindable var settings: SettingsStore
  let clipStore: any ClipStore

  @State private var showClearConfirm = false
  @State private var clearError: String?

  init(settings: SettingsStore, clipStore: any ClipStore) {
    self.settings = settings
    self.clipStore = clipStore
  }

  var body: some View {
    Form {
      Picker("Keep history for", selection: $settings.retentionMode) {
        Text("Everything").tag(SettingsStore.RetentionMode.unlimited)
        Text("Most recent items").tag(SettingsStore.RetentionMode.items)
        Text("A number of days").tag(SettingsStore.RetentionMode.days)
      }

      switch settings.retentionMode {
      case .unlimited:
        EmptyView()
      case .items:
        Stepper(
          "Keep \(settings.retentionItemCount) items",
          value: $settings.retentionItemCount,
          in: 10...100_000,
          step: 50
        )
      case .days:
        Stepper(
          "Keep \(settings.retentionDays) days",
          value: $settings.retentionDays,
          in: 1...365,
          step: 1
        )
      }

      Text("Pinned items are always kept.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Section {
        Button("Clear All History…", role: .destructive) {
          showClearConfirm = true
        }
        if let clearError {
          Text(clearError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Clear all clipboard history?",
      isPresented: $showClearConfirm,
      titleVisibility: .visible
    ) {
      Button("Clear All History", role: .destructive) {
        let store = clipStore
        Task {
          do {
            try await store.clearHistory()
            clearError = nil
          } catch {
            clearError = error.localizedDescription
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently deletes every captured item. This can't be undone.")
    }
  }
}
```

- [ ] **Step 2: Verify it builds**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -scheme ClipnestApp -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual smoke**

Launch, open Settings → History. Verify: switching the picker to "Most recent items" shows the item Stepper; "A number of days" shows the day Stepper; "Everything" shows neither. Lower the item cap below the current history size, copy something new → older unpinned items beyond the cap disappear from the picker while pinned items remain. "Clear All History…" prompts, and confirming empties the History tab of the picker.

- [ ] **Step 4: Stage**

```bash
git add ClipnestApp/Sources/UI/Settings/HistorySettingsView.swift
```

---

### Task 7: App — Shortcuts tab (rebind ⌥⌘V / ⌥⌘E)

Replace the Shortcuts stub with two `KeyboardShortcuts.Recorder`s bound to the already-defined `.togglePicker` / `.expandSnippet` names. The library persists and re-registers automatically — no other wiring needed.

**Files:**
- Modify (overwrite the stub): `ClipnestApp/Sources/UI/Settings/ShortcutsSettingsView.swift`

**Interfaces:**
- Consumes: `KeyboardShortcuts.Name.togglePicker`, `KeyboardShortcuts.Name.expandSnippet` (already defined in `HotkeyManager.swift`).

- [ ] **Step 1: Overwrite `ShortcutsSettingsView.swift`**

```swift
// ShortcutsSettingsView.swift
//
// The Shortcuts settings tab: rebind the two global hotkeys. Each Recorder
// binds to a KeyboardShortcuts.Name already defined in HotkeyManager.swift;
// the library persists the new binding and re-registers the live global
// hotkey itself, so there is nothing to wire back into AppEnvironment.

import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
  var body: some View {
    Form {
      KeyboardShortcuts.Recorder("Open Clipnest", name: .togglePicker)
      KeyboardShortcuts.Recorder("Expand snippet", name: .expandSnippet)
      Text("Click a shortcut and press the new key combination.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
  }
}
```

- [ ] **Step 2: Verify it builds**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -scheme ClipnestApp -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual smoke**

Launch, open Settings → Shortcuts. Verify both recorders show the current defaults (⌥⌘V, ⌥⌘E). Rebind "Open Clipnest" to a new combo; the new combo opens the picker from another app, and the binding survives an app relaunch.

- [ ] **Step 4: Stage**

```bash
git add ClipnestApp/Sources/UI/Settings/ShortcutsSettingsView.swift
```

---

### Task 8: App — Apps tab (excluded list + Add… via NSOpenPanel)

Replace the Apps stub with the excluded-apps manager: built-in password managers shown locked (unremovable), user apps removable, and an "Add…" button that reads a chosen app's bundle ID via `NSOpenPanel`. Add/remove/dedup logic is already unit-tested in Task 2.

**Files:**
- Modify (overwrite the stub): `ClipnestApp/Sources/UI/Settings/AppsSettingsView.swift`

**Interfaces:**
- Consumes: `SettingsStore.userExcludedBundleIDs/addExcludedApp/removeExcludedApp`, `PrivacyFilter.builtInExcludedBundleIDs`.

- [ ] **Step 1: Overwrite `AppsSettingsView.swift`**

```swift
// AppsSettingsView.swift
//
// The Apps settings tab: manage which apps are excluded from capture. Built-in
// password managers (PrivacyFilter.builtInExcludedBundleIDs) are shown locked
// and cannot be removed — they're always enforced inside PrivacyFilter. User
// exclusions are added by picking an .app bundle (its bundle ID is read via
// NSOpenPanel) and are removable. Add/remove/dedup logic is unit-tested in
// SettingsStoreTests; NSOpenPanel is a system boundary (manual-only).

import AppKit
import ClipnestCore
import SwiftUI

struct AppsSettingsView: View {
  @Bindable var settings: SettingsStore

  init(settings: SettingsStore) {
    self.settings = settings
  }

  /// Built-ins, sorted for a stable display order.
  private var builtInBundleIDs: [String] {
    PrivacyFilter.builtInExcludedBundleIDs.sorted()
  }

  var body: some View {
    Form {
      Section("Always excluded") {
        ForEach(builtInBundleIDs, id: \.self) { bundleID in
          HStack {
            Text(Self.displayName(forBundleID: bundleID))
            Spacer()
            Image(systemName: "lock.fill")
              .foregroundStyle(.secondary)
          }
        }
      }

      Section("Excluded apps") {
        if settings.userExcludedBundleIDs.isEmpty {
          Text("No apps excluded yet.")
            .foregroundStyle(.secondary)
        }
        ForEach(settings.userExcludedBundleIDs, id: \.self) { bundleID in
          HStack {
            Text(Self.displayName(forBundleID: bundleID))
            Spacer()
            Button {
              settings.removeExcludedApp(bundleID: bundleID)
            } label: {
              Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Remove")
          }
        }
        Button("Add…") {
          addApp()
        }
      }
    }
    .formStyle(.grouped)
  }

  /// Presents an app picker scoped to `.app` bundles and adds the chosen app's
  /// bundle identifier. NSOpenPanel runs modally from the active Settings
  /// window; a pick with no readable bundle ID is silently ignored.
  private func addApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Exclude"
    panel.message = "Choose an app to exclude from clipboard capture."

    guard panel.runModal() == .OK,
      let url = panel.url,
      let bundleID = Bundle(url: url)?.bundleIdentifier
    else {
      return
    }
    settings.addExcludedApp(bundleID: bundleID)
  }

  /// A friendly name for a bundle ID: the installed app's localized name if it
  /// can be resolved, otherwise the raw bundle ID (built-ins may not be
  /// installed on this machine — showing the ID is honest, not a failure).
  private static func displayName(forBundleID bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
      let name = Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
    {
      return name
    }
    return bundleID
  }
}
```

- [ ] **Step 2: Verify it builds**

Run: `cd ClipnestApp && xcodegen generate && xcodebuild -scheme ClipnestApp -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual smoke**

Launch, open Settings → Apps. Verify: the built-in password managers appear under "Always excluded" with a lock and no remove button. Click "Add…", choose an app (e.g. Notes) → it appears under "Excluded apps" with a remove button. Copy something in that app → it is NOT captured. Remove it → capturing from that app resumes. Relaunch → the exclusion persisted.

- [ ] **Step 4: Run all tests once more + stage**

Run: `swift test && cd ClipnestApp && xcodebuild -scheme ClipnestApp -destination 'platform=macOS' test`
Expected: PASS.

```bash
git add ClipnestApp/Sources/UI/Settings/AppsSettingsView.swift
```

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-08-14-settings-window-design.md`):
- §1 Surface & entry points → Task 5 (`Settings` scene, `SettingsLink`, Pause in menu, four-tab `TabView`). ✓
- §2 Persistence (one `SettingsStore`, typed keys, `retentionCap`, hotkeys not stored) → Task 2. Note: `launchAtLogin` is intentionally NOT in `SettingsStore` — `SMAppService` is its own source of truth (Task 3), avoiding a mirrored-bool drift. This is a deliberate refinement of the spec's §2 property list; behavior is unchanged. ✓
- §3 The four tabs → General (Task 5), History (Task 6), Shortcuts (Task 7), Apps (Task 8). ✓
- §4 Wiring into Core: excluded-apps provider + orthogonal pause gate + retention on launch/after-capture → Tasks 1 & 4. ✓
- §5 Errors & testing: SMAppService throws → inline error + revert (Task 5); clearHistory error inline (Task 6); Core capture-gate tests (Task 1); SettingsStore pure-logic tests (Task 2); system boundaries manual-only (Tasks 3, 5–8). ✓
- Resolved decisions: retention on launch + after each capture (Task 4); History as its own tab (Task 5 shell). ✓

**Placeholder scan:** The Task 5 stub views are intentional, compile-clean scaffolding, each *overwritten* wholesale by Tasks 6–8 (not appended), so no placeholder survives the plan. No "TBD"/"add error handling"/"write tests for the above" — every step has concrete code.

**Type consistency:** `SettingsStore.RetentionMode` cases (`unlimited`/`items`/`days`) are used identically in the store, tests, and History view. `retentionCap: RetentionCap?` returns `ClipnestCore.RetentionCap` (`.maxCount`/`.maxAge`), matching `ClipStore.enforceRetention(cap:)`. `captureEnabledProvider: @Sendable () -> Bool` signature matches between Task 1 (definition) and Task 4 (call site). `SettingsView.init(settings:clipStore:)` matches the call in `ClipnestApp`. `HistorySettingsView.init(settings:clipStore:)` and `AppsSettingsView.init(settings:)` match their stub signatures from Task 5.
