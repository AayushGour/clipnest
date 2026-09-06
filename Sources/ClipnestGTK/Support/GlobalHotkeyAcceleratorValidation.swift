// GlobalHotkeyAcceleratorValidation.swift
//
// T-OPT2 (Linux port, GTK4 view layer): pure validation + canonical-string
// conversion for a captured GLOBAL-hotkey key press — the counterpart of
// `KeyEventMapping.swift` for the Settings > Shortcuts recorder (the global
// toggle-picker hotkey), not the picker's own in-app chords. Deliberately
// split out of `SettingsWindow+Shortcuts.swift` (which owns the widget/GTK-
// signal side) so the actual accept/reject decision is a plain, fully
// unit-testable function — same reasoning as `KeyEventMapping.action(
// keyval:state:)`'s own top doc comment, and it reuses that file's
// modifier-mask constants (`controlMask`/`altMask`/`shiftMask`/`superMask`)
// rather than redefining them, per this task's explicit instruction: those
// are GDK's own ABI-stable bit values (`gdk/gdkenums.h`), the single source
// of truth in this module for "what a GDK modifier bit means."
//
// `gtk_accelerator_valid` alone is NOT sufficient for a global-hotkey
// recorder — verified empirically (a real `swift:6.0-jammy` +
// `libgtk-4-dev` probe, not assumed: `gtk_accelerator_valid(GDK_KEY_v, 0)`
// returns TRUE) that GTK considers a bare, unmodified printable key (e.g.
// plain `v`, no Control/Alt/Shift/Super held) a VALID accelerator — correct
// for a menu accelerator, wrong for a SYSTEM-WIDE global hotkey a user
// could trigger by accident while typing in any other app. This file adds
// that "at least one real modifier" requirement on top (this task's
// "reject ... an unmodified accelerator"); `gtk_accelerator_valid` itself
// still correctly rejects a bare modifier keypress alone (`Shift_L`/
// `Control_L`/`Alt_L`/`Super_L`/..., even while ANOTHER modifier is already
// held — verified empirically too) and a handful of other reserved
// keyvals, via GTK's own `invalid_accelerator_vals`/`invalid_unmodified_
// vals` tables, not reimplemented here.
import CGtk4

public enum GlobalHotkeyAcceleratorValidation {
  public enum Failure: Error, Equatable, Sendable {
    /// No real key was captured at all (`keyval == 0`) — this task's
    /// "reject an empty ... accelerator" requirement.
    case empty
    /// A real key was captured, but with none of Control/Alt/Shift/Super
    /// held — this task's "reject an unmodified accelerator" requirement.
    case noModifier
    /// `gtk_accelerator_valid` itself rejected the combination (a bare
    /// modifier key, or another GTK-reserved keyval).
    case notAnAccelerator
  }

  /// GDK modifier bits this recorder treats as "a real modifier" — the same
  /// four `KeyEventMapping` already defines, masked together once here
  /// rather than at each call site.
  static let modifierMask: UInt32 =
    KeyEventMapping.controlMask | KeyEventMapping.altMask | KeyEventMapping.shiftMask
    | KeyEventMapping.superMask

  /// Validates a captured `(keyval, GDK modifier-state bitmask)` pair — the
  /// same two raw values `GtkEventControllerKey`'s `key-pressed` signal
  /// reports, see `Window/SettingsWindow+Shortcuts.swift`'s trampoline — as
  /// a candidate GLOBAL accelerator and, on success, returns its canonical
  /// `gtk_accelerator_parse`-round-trippable string form (via GTK's own
  /// `gtk_accelerator_name` — never hand-formatted, so the ordering/spelling
  /// always matches what `gtk_accelerator_parse`/the GNOME Shell extension's
  /// `Main.wm.addKeybinding` actually expect).
  public static func validate(keyval: UInt32, state: UInt32) -> Result<String, Failure> {
    guard keyval != 0 else { return .failure(.empty) }
    let meaningfulModifiers = state & modifierMask
    guard meaningfulModifiers != 0 else { return .failure(.noModifier) }
    let mods = GdkModifierType(rawValue: meaningfulModifiers)
    guard gtk_accelerator_valid(keyval, mods) != 0 else { return .failure(.notAnAccelerator) }
    guard let cName = gtk_accelerator_name(keyval, mods) else { return .failure(.notAnAccelerator) }
    defer { g_free(cName) }
    return .success(String(cString: cName))
  }

  /// A human-readable label for an already-persisted accelerator string
  /// (e.g. `"<Super><Shift>v"` -> `"Super+Shift+V"`), for DISPLAY only — the
  /// stored/round-tripped value is always the canonical `gtk_accelerator_
  /// name` form from `validate(keyval:state:)` above, never this label.
  /// Returns `nil` if `accelerator` doesn't parse (an empty string, or
  /// anything `gtk_accelerator_parse` can't read — it reports failure by
  /// setting the parsed keyval to 0, GTK's own documented convention, not a
  /// thrown error — verified empirically that this also holds for a plain
  /// Swift `String` argument, not just a string literal).
  public static func displayLabel(for accelerator: String) -> String? {
    var keyval: UInt32 = 0
    var mods = GdkModifierType(rawValue: 0)
    gtk_accelerator_parse(accelerator, &keyval, &mods)
    guard keyval != 0 else { return nil }
    guard let cLabel = gtk_accelerator_get_label(keyval, mods) else { return nil }
    defer { g_free(cLabel) }
    return String(cString: cLabel)
  }
}
