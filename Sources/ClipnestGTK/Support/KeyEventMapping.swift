// KeyEventMapping.swift
//
// P7-D (Linux port, GTK4 view layer): the ONE place a raw GTK key-press
// (a GDK keyval + modifier-state bitmask) is translated into a
// `PickerKeyAction`. Everything else (`PickerWindow`'s `GtkEventControllerKey`
// "key-pressed" trampoline) only ever switches over the resulting action —
// see `PickerKeyAction.swift`'s doc comment.
//
// Deliberately takes plain `UInt32` for `keyval`/`state` rather than
// whatever Swift type name the Clang importer happens to give
// `GdkModifierType`/`guint` from `<gdk/gdk.h>` (an unstable implementation
// detail of the importer, not part of GDK's public ABI) — GDK keyvals and
// modifier-mask flags are, by contrast, PUBLIC, ABI-stable 32-bit integer
// constants (documented in `gdk/gdkenums.h`/`gdk/gdkkeysyms.h`; unchanged
// across GTK3->GTK4 and, for the keysyms, back to X11's own keysym table),
// so hardcoding their well-known numeric values here — rather than
// referencing whatever name/type the importer picked for the C enum cases —
// keeps this file's only external dependency on GTK/GDK itself pinned to
// facts that cannot silently change, and (more immediately useful) keeps it
// fully testable with plain integers, no `CGtk4` import needed at all.
// `PickerWindow`'s trampoline (the untestable edge — see this task's "Reality
// check") is the one place that must line up its own `@convention(c)`
// handler's parameter types with what GTK actually invokes; this file only
// ever receives the two `UInt32`s it already extracted.
public enum KeyEventMapping {
  /// GDK modifier-state bitmask flags this file cares about — mirrors
  /// `gdk/gdkenums.h`'s `GdkModifierType` (`GDK_CONTROL_MASK = 1 << 2`,
  /// `GDK_ALT_MASK = 1 << 3`; see this file's top doc comment for why
  /// these are hardcoded rather than imported), spelled out as named
  /// constants (not inline `4`/`8`) per coding-standards.md's no-magic-
  /// numbers rule. `controlMask` gates the Linux-conventional primary
  /// modifier (Ctrl+F/P/Delete/1/2/3 — this picker's substitute for
  /// macOS's ⌘-chords); `altMask` gates the Enter/plain-text variant,
  /// mirroring macOS's ⌥⏎ specifically (not ⌘⏎) — see `.commit`'s case
  /// below.
  static let controlMask: UInt32 = 1 << 2
  static let altMask: UInt32 = 1 << 3

  /// GDK keysym values (`gdk/gdkkeysyms.h`) this file maps — one named
  /// constant per key, not inlined at each `switch` case, for the same
  /// no-magic-numbers reason as `controlMask` above.
  private enum Keyval {
    static let up: UInt32 = 0xff52
    static let down: UInt32 = 0xff54
    static let `return`: UInt32 = 0xff0d
    /// The numeric keypad's Enter key — GTK reports it as a DIFFERENT
    /// keyval from `GDK_KEY_Return`, and a keyboard's numpad Enter is a
    /// completely ordinary way to commit a selection, so both map to
    /// `.commit` identically below.
    static let kpEnter: UInt32 = 0xff8d
    static let escape: UInt32 = 0xff1b
    /// GDK reports separate lower/upper-case keyvals for a letter key
    /// depending on Shift/CapsLock — `f`/`F`, `p`/`P` both need to keep
    /// meaning "the F/P key" regardless of case, since none of this
    /// picker's Ctrl-chords are case-sensitive (mirrors `ShortcutHints`'
    /// macOS bindings, which are likewise case-insensitive — ⌘F/⌘P, not
    /// ⌘⇧F).
    static let fLower: UInt32 = 0x066
    static let fUpper: UInt32 = 0x046
    static let pLower: UInt32 = 0x070
    static let pUpper: UInt32 = 0x050
    static let delete: UInt32 = 0xffff
    static let one: UInt32 = 0x031
    static let two: UInt32 = 0x032
    static let three: UInt32 = 0x033
  }

  /// Maps a raw `(keyval, state)` GTK key-press to the `PickerKeyAction` it
  /// should trigger, or `nil` if this picker doesn't bind that key.
  ///
  /// - Parameters:
  ///   - keyval: the GDK keysym reported by `GtkEventControllerKey`'s
  ///     "key-pressed" signal — e.g. `GDK_KEY_Up`'s numeric value (see
  ///     `Keyval` above).
  ///   - state: the `GdkModifierType` bitmask reported alongside it. Only
  ///     `controlMask` is consulted; every other bit (Shift, CapsLock, a
  ///     mouse-button chord, etc.) is ignored, matching how `GDK_CONTROL_
  ///     MASK`-gated shortcuts are conventionally checked (masking the bit
  ///     you care about, not requiring an exact full-state match, so e.g.
  ///     NumLock being on doesn't silently break every Ctrl-chord).
  public static func action(keyval: UInt32, state: UInt32) -> PickerKeyAction? {
    let isControlDown = state & controlMask != 0
    let isAltDown = state & altMask != 0

    switch keyval {
    case Keyval.up:
      return .moveUp
    case Keyval.down:
      return .moveDown
    case Keyval.return, Keyval.kpEnter:
      return .commit(plainText: isAltDown)
    case Keyval.escape:
      return .dismiss
    // NOTE (bug found by GTKKeyEventMappingTests, fixed here): `case a, b
    // where cond:` in Swift attaches `where` to ONLY THE LAST pattern in
    // the comma list, not to every pattern — `case Keyval.fLower,
    // Keyval.fUpper where isControlDown:` silently let plain `f` (no
    // Ctrl) match unconditionally, which a first pass of this switch got
    // wrong. Every multi-keyval-with-a-guard case below is written as a
    // plain `case` (no `where`) followed by an explicit ternary instead,
    // so the guard visibly applies to the whole case.
    case Keyval.fLower, Keyval.fUpper:
      return isControlDown ? .focusSearch : nil
    case Keyval.pLower, Keyval.pUpper:
      return isControlDown ? .togglePin : nil
    case Keyval.delete:
      return isControlDown ? .delete : nil
    case Keyval.one:
      return isControlDown ? .switchTab(.one) : nil
    case Keyval.two:
      return isControlDown ? .switchTab(.two) : nil
    case Keyval.three:
      return isControlDown ? .switchTab(.three) : nil
    default:
      return nil
    }
  }
}
