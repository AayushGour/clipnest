// AppDelegate.swift
//
// AppKit delegate for Clipnest. Belt-and-suspenders with `INFOPLIST_KEY_LSUIElement`
// (set in project.yml): explicitly sets the activation policy to `.accessory` so the
// app never shows a Dock icon and never steals focus from the frontmost app on launch.
//
// Also owns the single `AppEnvironment` (composition root), starts real
// clipboard capture, and registers the global picker hotkey on launch — see
// `AppEnvironment.swift`.

import AppKit
import ClipnestCore
import ClipnestViewModels
import Combine
import os

/// Bridges Clipnest's SwiftUI `App` to AppKit lifecycle events that SwiftUI's
/// `App` protocol doesn't expose directly (activation policy, app launch).
///
/// Conforms to `ObservableObject` (and publishes `environment`) so the SwiftUI
/// `Settings` scene, which reads `appDelegate.environment` through
/// `@NSApplicationDelegateAdaptor`, actually re-renders once the composition
/// root finishes building. `environment` is nil at App-init time and only set
/// later in `applicationDidFinishLaunching`; without publishing the change, the
/// scene stays frozen on its first evaluation — the "Starting Clipnest…"
/// fallback — because a plain stored `var` creates no SwiftUI dependency.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  private static let logger = Logger(subsystem: ClipnestLog.subsystem, category: "AppDelegate")

  @Published private(set) var environment: AppEnvironment?

  /// T-WELCOME1: the first-run welcome window. Created lazily with the
  /// environment; also reachable from the menu bar's "Getting Started…".
  private var welcomeController: WelcomeWindowController?

  /// Set by XCTest in the test-host process.
  private static let xcTestConfigurationEnvKey = "XCTestConfigurationFilePath"

  /// True when this process is the hosted unit-test run. The welcome window
  /// must not appear (or flip the real `hasSeenWelcome` flag) there.
  private var isHostingTests = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    // Single instance: a second copy (e.g. a build-output .app launched while
    // the installed one runs) would register the same global hotkeys, race
    // the first copy on every ⌥⌘V/⌥⌘E, and hold its own Accessibility grant —
    // so paste "works" or not depending on which copy got the key. Skipped
    // when hosting unit tests, which run inside a copy of this app and must
    // not quit just because the user's installed Clipnest is open.
    isHostingTests =
      ProcessInfo.processInfo.environment[Self.xcTestConfigurationEnvKey] != nil
    if !isHostingTests,
      let other = Self.otherRunningInstance(
        bundleID: Bundle.main.bundleIdentifier,
        ownPID: ProcessInfo.processInfo.processIdentifier,
        running: NSWorkspace.shared.runningApplications.map {
          (bundleID: $0.bundleIdentifier, pid: $0.processIdentifier)
        })
    {
      Self.logger.notice("Another Clipnest instance is running (pid \(other)); quitting this one")
      NSApplication.shared.terminate(nil)
      return
    }

    // T-PF1 (D1 launch-latency fix): `AppEnvironment.init` used to be a
    // plain synchronous `throws` initializer called directly here — nothing
    // in the app (menu bar icon, run loop) could proceed until the on-disk
    // SwiftData containers finished opening and their one-time backfills
    // finished scanning, all on the main thread. `AppEnvironment.init` is
    // now `async` and does that work off the main thread (see its doc
    // comment); wrapping the call in a `Task` here means THIS method
    // returns immediately instead of blocking on it, so
    // `applicationDidFinishLaunching` itself is fast regardless of how long
    // persistence setup takes. `environment` stays `nil` (already the
    // documented, handled state — see `SettingsRootView`/`MenuBarContent`
    // in `ClipnestApp.swift`, both already built around it being nil until
    // published) for a bit longer than before; nothing observed a
    // synchronous guarantee that it would be non-nil by the time this
    // method returned.
    Task { await self.launchEnvironment() }
  }

  private func launchEnvironment() async {
    do {
      start(try await AppEnvironment())
    } catch {
      // The persistence layer already self-heals a corrupt store once
      // (`ModelContainerRecovery`), so reaching here is a real failure. Log
      // metadata only (never clipboard content), then tell the user instead
      // of vanishing silently (T-STOREALERT1).
      Self.logger.fault("Failed to initialize AppEnvironment: \(String(describing: error))")
      await recoverFromLaunchFailure(error)
    }
  }

  /// - Parameter welcomeSuppressed: `true` on the store-failure recovery
  ///   relaunch inside the same process — that alert owned this launch, so
  ///   the welcome (and the Accessibility prompt it replaces) waits until the
  ///   next normal launch.
  private func start(_ environment: AppEnvironment, welcomeSuppressed: Bool = false) {
    self.environment = environment
    environment.startCapture()
    environment.registerHotkey()
    environment.startUpdateChecking()
    environment.enforceRetentionNow()
    presentWelcomeOrRequestAccessibility(environment, suppressed: welcomeSuppressed)
  }

  /// T-WELCOME1: while the welcome is unseen it owns the Accessibility ask
  /// (step 1, on a button press), so the old launch-time system prompt must
  /// not stack on top of it. Once seen, the original once-ever nudge applies
  /// unchanged. Read the flag BEFORE `WelcomeGate` flips it.
  private func presentWelcomeOrRequestAccessibility(
    _ environment: AppEnvironment, suppressed: Bool
  ) {
    guard !isHostingTests else {
      environment.requestAccessibilityOnceIfNeeded()
      return
    }
    let settings = environment.settingsStore
    let suppressPrompt = WelcomeGate.suppressesLaunchAccessibilityPrompt(
      hasSeenWelcome: settings.hasSeenWelcome)
    if WelcomeGate.presentIfNeeded(settings: settings, isSuppressed: suppressed) {
      showWelcome()
    } else if !suppressPrompt {
      // Checks first, prompts at most once ever, and only if actually
      // missing — see the method's doc comment. The picker hotkey needs
      // Accessibility as of the ⌥⌘V pass-through fix, so a first-run user
      // has to be told something.
      environment.requestAccessibilityOnceIfNeeded()
    }
  }

  /// Opens (or re-fronts) the welcome window. Does not touch the seen flag, so
  /// "Getting Started…" can call it freely.
  func showWelcome() {
    guard let environment else { return }
    let controller = welcomeController ?? WelcomeWindowController(environment: environment)
    welcomeController = controller
    controller.show()
  }

  /// Alert -> optional reset (move aside, never delete) -> one retry -> quit.
  private func recoverFromLaunchFailure(_ error: Error) async {
    switch StoreOpenFailureAlert.ask(error: error) {
    case .quit:
      break
    case .showInFinder:
      StoreOpenFailureAlert.revealDataFolder()
    case .resetHistory:
      var backup: URL?
      do {
        backup = try StoreOpenFailureRecovery.moveStoresAside(
          in: BlobStore.defaultBaseDirectory())
        start(try await AppEnvironment(), welcomeSuppressed: true)
        return
      } catch {
        Self.logger.fault("Reset-and-retry failed: \(String(describing: error))")
        StoreOpenFailureAlert.showFinalFailure(error: error, backupFolder: backup)
      }
    }
    NSApplication.shared.terminate(nil)
  }

  /// The pid of another running process with this app's bundle ID, if any.
  /// Pure so it is unit-testable without launching a second copy.
  nonisolated static func otherRunningInstance(
    bundleID: String?, ownPID: pid_t, running: [(bundleID: String?, pid: pid_t)]
  ) -> pid_t? {
    guard let bundleID else { return nil }
    return running.first { $0.bundleID == bundleID && $0.pid != ownPID }?.pid
  }

  /// The menu bar "Open Clipnest" item's action (`ClipnestApp.swift`).
  func showPicker() {
    environment?.showPicker()
  }
}
