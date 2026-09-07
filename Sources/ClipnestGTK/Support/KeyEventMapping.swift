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
  /// modifier (Ctrl+F/P/S/N/1/2/3/, — this picker's substitute for macOS's
  /// ⌘-chords); Delete is the one exception — it matches with or without
  /// Ctrl held, see `Keyval.delete`'s case below for why. `altMask` gates
  /// the Enter/plain-text variant, mirroring macOS's ⌥⏎ specifically (not
  /// ⌘⏎) — see `.commit`'s case below.
  ///
  /// Keyboard-parity pass (routed follow-up): four more Ctrl-chords added —
  /// `Ctrl+S` (save highlighted as snippet), `Ctrl+N` (new snippet, Snippets
  /// tab only), `Ctrl+Shift+E` (replace/edit the highlighted snippet — needs
  /// `shiftMask` too, see `Keyval.eLower`/`Keyval.eUpper`'s case below), and
  /// `Ctrl+,` (open Settings) — mirroring macOS's `⌘S`/`⌘N`/the mouse-only
  /// "Edit" snippet action/`⌘,`. All four are ordinary Ctrl-chords a plain
  /// `GtkEntry` does not itself bind, and — like every other chord in this
  /// file — are intercepted at `GTK_PHASE_CAPTURE` before the focused search
  /// entry ever sees them (see
  /// `PickerKeyAction.isTextEditingKeyWhenTypingInSearch`'s doc comment), so
  /// none of the four needs that flag.
  static let controlMask: UInt32 = 1 << 2
  static let altMask: UInt32 = 1 << 3

  /// `GDK_SHIFT_MASK` / `GDK_SUPER_MASK` — bit values verified against
  /// GTK's own `gdk/gdkenums.h` (not guessed): Shift is `1 << 0`; Super
  /// (the "Windows"/Meta key most Linux keyboards actually have) is
  /// `1 << 26` — GTK4 dropped the legacy X11 `Mod1`-`Mod5` bits entirely
  /// (`GDK_MOD1_MASK` was renamed `GDK_ALT_MASK`, `GDK_MOD2_MASK` renamed
  /// `GDK_META_MASK`), so Super is the closest, most-likely-to-exist
  /// analogue of macOS's ⌘ for this "modifier Return doesn't implement
  /// anything for" check below. Used only by `returnAction(forState:)`.
  static let shiftMask: UInt32 = 1 << 0
  static let superMask: UInt32 = 1 << 26

  /// `GDK_LOCK_MASK` — "Caps Lock (or Shift Lock, depending on the
  /// windowing system configuration)" per GDK's own documentation: a
  /// TOGGLE state, not a modifier the user is deliberately holding down to
  /// request a different action. Masked out before deciding Return's
  /// action (T-BUG1/parity-audit bug #4) — mirrors macOS's
  /// `PickerView.returnAction(for:)` excluding `.capsLock` for exactly the
  /// same reason: a plain Return pressed with Caps Lock toggled on must
  /// still commit normally, not be silently ignored. (GDK has no Num Lock
  /// bit in `GdkModifierType` at all — verified against GTK's own source;
  /// Num Lock is only queryable via `GdkDevice.numLockState`, so unlike
  /// macOS there is nothing further to exclude for the numeric-keypad half
  /// of that same exclusion — `Keyval.kpEnter` below already unifies the
  /// numpad Enter keyval with plain Return at the KEYVAL level instead.)
  static let lockMask: UInt32 = 1 << 1

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
    /// Keyboard-parity pass: `s`/`S` (Ctrl+S, save highlighted as snippet),
    /// `n`/`N` (Ctrl+N, new snippet), `e`/`E` (Ctrl+Shift+E, replace/edit the
    /// highlighted snippet) — same lower/upper-case-both-mean-the-key
    /// reasoning as `fLower`/`fUpper` above. `comma` (Ctrl+,, open Settings)
    /// has no case variant to worry about — it isn't a letter.
    static let sLower: UInt32 = 0x073
    static let sUpper: UInt32 = 0x053
    static let nLower: UInt32 = 0x06e
    static let nUpper: UInt32 = 0x04e
    static let eLower: UInt32 = 0x065
    static let eUpper: UInt32 = 0x045
    static let comma: UInt32 = 0x02c
  }

  /// Maps a raw `(keyval, state)` GTK key-press to the `PickerKeyAction` it
  /// should trigger, or `nil` if this picker doesn't bind that key.
  ///
  /// - Parameters:
  ///   - keyval: the GDK keysym reported by `GtkEventControllerKey`'s
  ///     "key-pressed" signal — e.g. `GDK_KEY_Up`'s numeric value (see
  ///     `Keyval` above).
  ///   - state: the `GdkModifierType` bitmask reported alongside it. Every
  ///     Ctrl-gated case below (`focusSearch`/`togglePin`/`switchTab`)
  ///     consults only `controlMask`, ignoring every other bit (Shift, Lock,
  ///     a mouse-button chord, etc.) — masking the bit you care about, not
  ///     requiring an exact full-state match, so e.g. Caps Lock being on
  ///     doesn't silently break every Ctrl-chord. `delete` ignores `state`
  ///     entirely (see its case below — bare Delete and Ctrl+Delete are both
  ///     accepted). Return/numpad-Enter is the other exception:
  ///     `returnAction(forState:)` below also consults Shift/Super (and
  ///     masks out Lock) so an unimplemented modifier held on Return is
  ///     reported as unhandled rather than silently aliased to plain Return
  ///     (T-BUG1/parity-audit bug #4).
  public static func action(keyval: UInt32, state: UInt32) -> PickerKeyAction? {
    let isControlDown = state & controlMask != 0
    // Keyboard-parity pass: only `Ctrl+Shift+E` (`.replaceSnippet`) below
    // consults this — every other Ctrl-chord in this file is deliberately
    // Shift-agnostic (Caps Lock/Shift held incidentally must not break e.g.
    // Ctrl+F), matching this file's existing masking-not-exact-match
    // philosophy (see this method's own doc comment above).
    let isShiftDown = state & shiftMask != 0

    switch keyval {
    case Keyval.up:
      return .moveUp
    case Keyval.down:
      return .moveDown
    case Keyval.return, Keyval.kpEnter:
      return returnAction(forState: state)
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
    // Bare Delete now deletes, matching macOS's `PickerView.handle(_:)`
    // `.delete` case, which — per that method's own "Reliability note
    // (T24)" doc comment — "matches the physical Delete key regardless of
    // modifiers, so this one case covers both plain Delete and ⌘⌫." Linux
    // previously required Ctrl+Delete, an inconsistency with no platform
    // reason behind it (GTK has no text-field-swallows-bare-Delete
    // complication the way macOS's always-focused search field does).
    // Ctrl+Delete is DELIBERATELY kept working too — not narrowed to just
    // bare Delete — because it's this app's already-documented/shipped
    // Linux convention (`LinuxShortcutDescriptions.swift`'s Settings ->
    // Shortcuts listing, and this file's own prior test suite); a user who
    // already learned Ctrl+Delete must not have it stop working. Ignoring
    // `state` entirely (rather than special-casing "state == 0 ||
    // isControlDown") makes bare Delete a superset of the old behavior, not
    // a replacement — every modifier combination that used to delete still
    // does, plus the one that didn't (plain Delete) now also does.
    case Keyval.delete:
      return .delete
    case Keyval.one:
      return isControlDown ? .switchTab(.one) : nil
    case Keyval.two:
      return isControlDown ? .switchTab(.two) : nil
    case Keyval.three:
      return isControlDown ? .switchTab(.three) : nil
    // Keyboard-parity pass (routed follow-up): four more Ctrl-chords,
    // mirroring macOS's ⌘S/⌘N/(mouse-only Edit action)/⌘, — see this
    // method's top doc comment. Written as plain `case`s with a ternary
    // (never `case a, b where cond:`), same discipline as every other
    // multi-keyval-with-a-guard case above, for the exact reason this file's
    // top "NOTE (bug found by ...)" comment documents.
    case Keyval.sLower, Keyval.sUpper:
      return isControlDown ? .saveAsSnippet : nil
    case Keyval.nLower, Keyval.nUpper:
      return isControlDown ? .newSnippet : nil
    // `Ctrl+Shift+E`, not bare `Ctrl+E`: verified at runtime (this task's own
    // container test) that a bare `Ctrl+E` here would collide with nothing
    // GTK/the search entry binds by default, but Shift is required anyway
    // per this task's spec (`Ctrl+Shift+E`) — GDK reports `E`'s *shifted*
    // keyval (`Keyval.eUpper`) plus `GDK_SHIFT_MASK` in `state` when Shift is
    // physically held, so both are checked explicitly rather than assumed
    // redundant.
    case Keyval.eLower, Keyval.eUpper:
      return isControlDown && isShiftDown ? .replaceSnippet : nil
    case Keyval.comma:
      return isControlDown ? .openSettings : nil
    default:
      return nil
    }
  }

  /// T-BUG1 (parity-audit bug #4): decides Return/numpad-Enter's action —
  /// mirrors macOS's `PickerView.returnAction(for:)` fix for the exact same
  /// defect (see that method's doc comment): the previous single-line
  /// `.commit(plainText: isAltDown)` silently treated ANY modifier other
  /// than Alt (Shift+Return, Ctrl+Return, Super+Return, ...) as if it were
  /// plain Return, with no indication anything differed. `lockMask` (Caps/
  /// Shift Lock) is masked out FIRST since it's an incidental toggle, not a
  /// held-down request — see that constant's doc comment.
  ///
  /// - Returns: `.commit(plainText: true)` when Alt is held (checked
  ///   first, so e.g. Alt+Shift+Return still commits plain text, exactly
  ///   like macOS's ⌥⌘Return still selecting plain text); `nil` (ignored —
  ///   `PickerWindow.handleKeyPressed` then reports `GDK_EVENT_PROPAGATE`,
  ///   letting the keypress fall through unhandled, matching macOS's
  ///   `.ignore` → `.ignored`) when Shift, Control, or Super is held
  ///   without Alt; `.commit(plainText: false)` (plain Return) otherwise.
  private static func returnAction(forState state: UInt32) -> PickerKeyAction? {
    let meaningfulState = state & ~lockMask
    guard meaningfulState & altMask == 0 else {
      return .commit(plainText: true)
    }
    let unimplementedReturnModifiers = shiftMask | controlMask | superMask
    guard meaningfulState & unimplementedReturnModifiers == 0 else {
      return nil
    }
    return .commit(plainText: false)
  }
}
