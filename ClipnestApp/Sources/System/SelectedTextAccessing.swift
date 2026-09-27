// SelectedTextAccessing.swift
//
// Reads and replaces the currently-selected text in the frontmost app via
// the Accessibility API (AX) — WITHOUT touching the pasteboard. Used by the
// snippet-expansion hotkey (see `SnippetExpander`). The `SelectedTextAccessing`
// protocol itself lives in `ClipnestCore` (so `SnippetExpander`'s decision
// logic is unit-testable with a mock, mirroring `Paster`'s
// protocol-in-Core/concrete-impl-in-app split); this file holds only the
// real AX-backed implementation, which is manual-verify only.
//
// `@preconcurrency import ApplicationServices`: the AX C API predates Swift
// concurrency auditing (same reason `PermissionsManager` needs it — see
// project-context.md D13), so importing it plainly can trip strict-
// concurrency diagnostics on its global constants.
//
// T-ELEC1 (2026-09): investigating "snippet expansion doesn't replace text in
// Electron apps" (reported against VS Code + the Claude desktop app), real
// reproduction in VS Code and Antigravity IDE (both confirmed Electron) found
// TWO independent failure modes, not one:
//   1. In VS Code, `readSelectedText()` most commonly returns `nil` (AX
//      genuinely can't read the selection). A later cross-app AX-fidelity
//      survey (2026-09, see D97) found a second, coexisting shape of the
//      same failure in VS Code/Antigravity plain-text buffers: AX answers
//      `.success` with an EMPTY string, role `AXTextArea` (allowlisted) —
//      this method passes that empty string through as-is rather than
//      folding it into `nil` (verified correct: `SnippetExpander.expand()`'s
//      own blank-check, `!selection...isEmpty`, treats an empty string
//      exactly like `nil`, so no code change was needed here). Either way,
//      `SnippetExpander` falls through to `ClipboardSelectionReplacer`'s
//      clipboard fallback, which worked correctly in every trial run
//      against it — see that file's own T-ELEC1 note for the timing
//      evidence.
//   2. In Antigravity IDE, `AXUIElementCopyAttributeValue` for
//      `kAXSelectedTextAttribute` returned `.success` with a 294-character
//      string while the user's actual selection was 4 characters ("test") —
//      a false positive, not a failure. The focused element's role was
//      `AXWebArea` (the root web-content node), not a text field/area: a
//      Monaco/canvas-based editor that hasn't switched into full
//      accessibility mode (`editor.accessibilitySupport`, off by default
//      until a screen reader is detected) never moves real AX focus down to
//      an editable text control, so AX reports the top-level web area as
//      focused and answers `kAXSelectedTextAttribute` from the underlying
//      DOM `Selection` (stale/unrelated to the editor's own cursor) instead
//      of failing outright.
//
// D97 (2026-09-12, project-context.md): `AXError.success` only certifies the
// target app ACCEPTED the call — never that the operation took EFFECT, and
// never that the answered attribute was SCOPED to the control the user is
// actually looking at. T-ELEC1's `AXWebArea` case above is a scope lie (read
// side); T-SAFARI1 below found the mirror-image effect lie on the write
// side. Both are the same conflation, fixed with two independent, additive
// mechanisms — a role ALLOWLIST for reads, a before/after re-read for
// writes — because they guard different operations failing for unrelated
// reasons (staleness vs. phantom effect) and are verified by different
// signals (role eligibility vs. range comparison); see D97-D99.
//
// T-AXTRUST1 (2026-09-12): generalized `isTrustworthy(role:)` from T-ELEC1's
// single `AXWebArea` denylist entry to a positive role ALLOWLIST
// (`trustedEditableRoles`) per explicit user direction to fix the root cause
// rather than pattern-match individual hostile apps (D98) — the literal
// `AXWebArea` string is gone; it would never appear on a list of known
// editable-text roles, so the allowlist subsumes the old denylist rather
// than sitting beside it. Also flips `isTrustworthy(role: nil)` from
// trusted to UNTRUSTED (D99) — an unreadable role is exactly the kind of
// uncertainty this contract routes to the clipboard fallback, and T-ELEC1
// had deliberately left that one case open as a known gap outside its scope.
//
// T-SAFARI1 (2026-09-12): fixed the effect-lie half of D97. Safari/WebKit's
// `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)` was found (via
// screenshot-verified manual trials across `<input>`, `<textarea>`, and
// `contenteditable`) to return `.success` while the field is PROVABLY
// UNCHANGED — and Safari's roles are `AXTextField`/`AXTextArea`, both on the
// trusted allowlist, so the read-side role guard alone can never catch this.
// `replaceSelectedText` now captures `kAXSelectedTextRangeAttribute` (a
// REQUIRED attribute on any AX text control, unlike the optional
// `kAXStringForRangeParameterizedAttribute`) before the write and once more
// after a `.success` result; an unchanged or unreadable-either-time range is
// treated as an unverified phantom write and reported as `false`, which
// `SnippetExpander` already routes to the clipboard fallback — see
// `rangeChanged(before:after:)`. This is one deterministic re-read, not a
// poll; nothing here sleeps or loops (a prior attempt in this codebase to
// replace a fixed delay with an observed-state poll caused a reproducible
// ~400ms stall and was reverted — see T-ELEC1's note in
// project-context.md).
//
// DELIBERATELY UNCONDITIONAL: `replaceSelectedText`'s range check runs for
// EVERY write, regardless of role — it is NOT gated behind
// `trustedEditableRoles` or narrowed to WebKit/Safari specifically. The
// same 2026-09 cross-app survey that found the empty-string read above also
// found phantom-writing `AXTextArea`/`AXTextField` elements in Brave
// (Chromium/Blink), VS Code and Antigravity (Electron/Monaco), and —
// tellingly — Apple's own Terminal.app (native AppKit, a custom VT100/PTY
// renderer, not `NSTextView`): `AXUIElementSetAttributeValue` returns
// `.success` there too while the terminal is provably unchanged. Phantom
// writes are NOT correlated with role or toolkit; TextEdit was the only
// honest writer found across the whole survey. Do not let a future change
// scope this check down to "just Safari" or gate it behind the read-side
// allowlist — reads and writes are independent trust problems (D97), and
// this is the write side's only defense.
//
// Net effect: `readSelectedText`/`replaceSelectedText` now only ever report
// success when the selection is BOTH scoped to a trusted editable control
// AND the write is confirmed to have taken effect — closing both the scope
// lie and the effect lie without touching `SnippetExpander`'s existing
// fallback wiring, which was always correct.

@preconcurrency import ApplicationServices
import ClipnestCore
import os

/// Production `SelectedTextAccessing` backed by the system-wide AX element.
struct AXSelectedTextAccessor: SelectedTextAccessing {
  /// AX roles whose `kAXSelectedTextAttribute` is trusted for the
  /// destructive replace-in-place path (D98). Every macOS-standard editable
  /// text control role, stable since AppKit's original AX support — these
  /// are raw Apple AX identifiers matching this file's existing pattern
  /// (`kAXSelectedTextAttribute` et al. are equally stringly-typed C
  /// constants; there is no named Swift constant for the role strings
  /// themselves at this project's macOS 14 floor, coding-standards.md).
  /// Positive allowlist, not a per-app/per-framework denylist (T-AXTRUST1,
  /// D98) — a hostile or unrecognized role (`AXWebArea`, a synthetic
  /// `AXGroup` wrapper, a future AX-hostile framework's own container role)
  /// is untrusted simply by NOT appearing here, with no need to enumerate
  /// it explicitly.
  private static let trustedEditableRoles: Set<String> = [
    "AXTextField", "AXTextArea", "AXComboBox", "AXStaticText", "AXSecureTextField",
  ]

  /// Logged at `.notice` (persisted to the unified log, unlike `.debug` —
  /// see `HotkeyManager.applyDeliveryMode`'s identical reasoning) so which
  /// branch of `SnippetExpander`'s two-strategy design actually fired is
  /// answerable from a user's Mac via `log show`, without asking them to
  /// reproduce live. Metadata only: result codes, string LENGTH, and the AX
  /// role — never the selected/replaced text itself.
  private static let logger = Logger(
    subsystem: ClipnestLog.subsystem, category: "AXSelectedTextAccessor")

  func readSelectedText() -> String? {
    guard let focused = focusedElement() else {
      Self.logger.notice("readSelectedText: no focused AX element -> nil")
      return nil
    }
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(
      focused, kAXSelectedTextAttribute as CFString, &value)
    guard result == .success, let string = value as? String else {
      Self.logger.notice(
        "readSelectedText: AXError=\(result.rawValue, privacy: .public) -> nil")
      return nil
    }
    let role = role(of: focused)
    guard Self.isTrustworthy(role: role) else {
      Self.logger.notice(
        """
        readSelectedText: ignoring untrustworthy selection from \
        role=\(role ?? "nil", privacy: .public) (length=\(string.count, privacy: .public) \
        chars) -> nil, falling back to the clipboard path
        """)
      return nil
    }
    Self.logger.notice(
      """
      readSelectedText: success, length=\(string.count, privacy: .public) chars, \
      role=\(role ?? "nil", privacy: .public)
      """)
    return string
  }

  /// T-SAFARI1: Safari/WebKit's `AXUIElementSetAttributeValue` was found to
  /// return `.success` while the field is provably unchanged (D97's "effect
  /// lie"), so a bare `AXError` is not trusted here — the fast-fail path
  /// (write refused outright) is unchanged and costs nothing extra; a
  /// `.success` result gets one additional, non-looping re-read to confirm
  /// the selection actually moved before this method reports success.
  @discardableResult
  func replaceSelectedText(with text: String) -> Bool {
    guard let focused = focusedElement() else {
      Self.logger.notice("replaceSelectedText: no focused AX element -> false")
      return false
    }
    let rangeBefore = selectedTextRange(of: focused)
    let result = AXUIElementSetAttributeValue(
      focused, kAXSelectedTextAttribute as CFString, text as CFString)
    guard result == .success else {
      Self.logger.notice(
        "replaceSelectedText: AXError=\(result.rawValue, privacy: .public) ok=false")
      return false
    }
    let rangeAfter = selectedTextRange(of: focused)
    let rangeChanged = Self.rangeChanged(before: rangeBefore, after: rangeAfter)
    Self.logger.notice(
      """
      replaceSelectedText: AXError=\(result.rawValue, privacy: .public) ok=true \
      rangeChanged=\(rangeChanged, privacy: .public)
      """)
    return rangeChanged
  }

  /// Whether a `.success` `kAXSelectedTextAttribute` read from an element
  /// with this role should be trusted for a destructive text replacement.
  /// Pure and free of any AX call so it's directly unit-testable — see
  /// `AXSelectedTextAccessorTests` — mirroring `Paster.isStillFrontmost`'s
  /// precedent of extracting the decision from the system call that feeds it.
  ///
  /// `nil` (role couldn't be read at all) is now UNTRUSTED (T-AXTRUST1, D99
  /// — flipped from T-ELEC1's original "trust it"): an unreadable role is
  /// exactly the kind of uncertainty this contract (D97) routes to the
  /// clipboard fallback rather than trusting blindly.
  static func isTrustworthy(role: String?) -> Bool {
    guard let role else { return false }
    return trustedEditableRoles.contains(role)
  }

  /// The AX role of `element` (`kAXRoleAttribute`), or `nil` if it can't be
  /// read.
  private func role(of element: AXUIElement) -> String? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    else { return nil }
    return value as? String
  }

  /// The current `kAXSelectedTextRangeAttribute` for `element`, or `nil` if
  /// it can't be read. `kAXSelectedTextRangeAttribute` is a REQUIRED
  /// attribute on any AX text control (unlike the optional
  /// `kAXStringForRangeParameterizedAttribute`), which is why T-SAFARI1
  /// chose it as the write-verification signal in `replaceSelectedText`.
  private func selectedTextRange(of element: AXUIElement) -> CFRange? {
    var value: AnyObject?
    guard
      AXUIElementCopyAttributeValue(
        element, kAXSelectedTextRangeAttribute as CFString, &value) == .success
    else { return nil }
    // The attribute isn't a plain CF type — AX boxes non-primitive values
    // (here, a `CFRange`) in an `AXValueRef`. Verify the CFType before
    // bridging, same discipline as `focusedElement()` above: `CFGetTypeID`
    // dereferences without a null-check (a `.success` result with a nil
    // out-value would crash), and an un-verified force-cast could silently
    // bridge the wrong CFType.
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    // Verified above via `CFGetTypeID` to actually be an `AXValue`, so this
    // is the same sanctioned, provably-non-trapping force-cast exception as
    // `focusedElement()`'s — not a new one.
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return range
  }

  /// Whether a before/after `kAXSelectedTextRangeAttribute` pair proves a
  /// `.success` `replaceSelectedText` write actually took effect. Pure and
  /// free of any AX call so it's directly unit-testable — see
  /// `AXSelectedTextAccessorTests` — same "extract the decision" precedent
  /// as `isTrustworthy(role:)` above.
  ///
  /// An unreadable range on EITHER side, or an unchanged range, is treated
  /// as an unverified phantom write (D97): Safari/WebKit's
  /// `AXUIElementSetAttributeValue` was found to return `.success` while
  /// the field is provably unchanged, so "no error" alone is never enough —
  /// only a range that's readable both times AND actually different counts
  /// as a verified write.
  static func rangeChanged(before: CFRange?, after: CFRange?) -> Bool {
    guard let before, let after else { return false }
    return before.location != after.location || before.length != after.length
  }

  /// The system-wide focused UI element, or `nil` if none / AX unavailable.
  private func focusedElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var focused: AnyObject?
    let result = AXUIElementCopyAttributeValue(
      systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
    guard result == .success else { return nil }
    // `focused` is an AXUIElement (a CFType); bridge it back. Unwrap before
    // calling `CFGetTypeID` — it dereferences its argument and does not
    // null-check, so a `.success` result with a nil out-value would crash
    // (EXC_BAD_ACCESS) if passed straight through.
    guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    // `focused` is verified above to be an `AXUIElement` via `CFGetTypeID`, so
    // this cast cannot fail. `as!` is the *only* option the language allows for
    // bridging a `CFTypeRef` to a concrete CoreFoundation type: `as?` is a hard
    // compile error ("conditional downcast to CoreFoundation type … will always
    // succeed"), and `unsafeBitCast`/`unsafeDowncast` are strictly less safe.
    // This is the one sanctioned force-cast exception to coding-standards.md —
    // a post-`CFGetTypeID`-verified CF bridge that provably never traps.
    return focused as! AXUIElement
  }
}
