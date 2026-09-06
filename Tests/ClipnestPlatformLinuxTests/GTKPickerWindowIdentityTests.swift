// GTKPickerWindowIdentityTests.swift
//
// T-RT3 (Linux port, GTK4 view layer): pins `PickerWindow.role`/
// `.displayTitle` — the two constants that replaced, respectively, the
// former per-invocation `UUID().uuidString` `windowToken` value and the
// former "window title == windowToken" wiring (`PickerWindow.swift:171`
// previously did `gtk_window_set_title(window, windowToken)` directly).
// This is the wire-contract half of the fix: `role` is what
// `PlaceWindow`/`UnplaceWindow` (`ShellHelperProtocol.swift`) now sends as
// `windowToken` on every call, coordinated with the GNOME Shell extension's
// `_findByToken` rewrite (a different agent's concurrent change, same
// session — see `PickerWindow.swift`'s top "WINDOW PLACEMENT" doc comment).
// Actually constructing a real `PickerWindow` and reading its live
// `.windowToken`/GTK title back needs a GTK display, so that half is an
// untestable GTK edge verified at runtime instead (`wmctrl`/`xprop` against
// the live picker — see this task's own verification) — see
// `GTKKeyEventMappingTests.swift`'s top doc comment for this module's
// shared `ClipnestPlatformLinuxTests` -> `ClipnestGTK` manifest-dependency
// note.
import Testing

@testable import ClipnestGTK

@Suite("PickerWindow role/title constants")
struct GTKPickerWindowIdentityTests {
  @Test("windowToken's value is the stable role string \"picker\", not a UUID")
  func roleIsStablePickerString() {
    #expect(PickerWindow.role == "picker")
  }

  @Test("the window's user-visible title is the human-readable \"Clipnest\"")
  func displayTitleIsHumanReadable() {
    #expect(PickerWindow.displayTitle == "Clipnest")
  }

  @Test("role and displayTitle are deliberately different values (title is no longer the token)")
  func roleAndTitleAreDistinct() {
    #expect(PickerWindow.role != PickerWindow.displayTitle)
  }
}
