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
