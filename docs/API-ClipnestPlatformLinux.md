# ClipnestPlatformLinux — Accessibility (AT-SPI) API reference

Linux-only (`#if os(Linux)`, see `Package.swift`). This page documents the
`Sources/ClipnestPlatformLinux/Accessibility/**` subsystem — the AT-SPI2
D-Bus client behind `SnippetExpander`'s Accessibility-first tier — which is
genuinely, verifiably functional as of this writing (see
[Verified behavior](#verified-behavior-not-assumed) below). It does not
document `ClipnestPlatformLinux`'s other subsystems (`Clipboard/`, `Input/`)
— see [`docs/API-ClipnestLinuxAppKit.md`](API-ClipnestLinuxAppKit.md) for the
composition root that wires this subsystem in, and
[`docs/API.md`](API.md) for the shared `ClipnestCore` contract
(`SelectedTextAccessing`, `SnippetExpander`) this subsystem implements one
side of.

## Contents
- [How the tier is selected](#how-the-tier-is-selected)
- [`AccessibilityBusResolver`](#accessibilitybusresolver)
- [`ATSPIFocusTracker`](#atspifocustracker)
- [`ATSPITextAccessor`](#atspitextaccessor)
- [Verified behavior (not assumed)](#verified-behavior-not-assumed)
- [Coverage](#coverage)
- [Working example](#working-example)

## How the tier is selected

`SnippetExpander` (`ClipnestCore`) takes any `SelectedTextAccessing` — this
module's `ATSPITextAccessor` is the real, on-bus implementation; a fresh
`NullSelectedTextAccessing` (private to `LinuxAppEnvironment`, always
returns `nil`/`false`) is the deliberate degrade-to-clipboard-only stand-in
when no accessibility bus is reachable. `LinuxAppEnvironment
.makeSelectedTextAccessing()` picks between them ONCE, at Clipnest's own
launch, entirely by whether the real bus resolves and connects — never a
silently-defaulted seam (see coding-standards.md's cross-platform-seam
non-negotiable). `SnippetExpander` itself then falls through to its
universal clipboard-replace tier on ANY `false`/`nil` from whichever it was
given — so a mid-session AT-SPI failure (a hung/crashed target app, a call
timing out) degrades per-invocation, not just at startup.

## `AccessibilityBusResolver`

```swift
public enum AccessibilityBusResolver {
  public static func resolveAddress(
    sessionBusAddress: String, timeout: Duration = ATSPIConstants.callTimeout
  ) -> String?

  public static func isAccessibilityEnabled(
    sessionBusAddress: String, timeout: Duration = ATSPIConstants.callTimeout
  ) -> Bool?
}
```

`resolveAddress` calls `org.a11y.Bus.GetAddress` on the SESSION bus and
returns the private a11y bus address to connect everything else to, or
`nil` on any failure (no session bus, the call times out, a malformed
reply). **Verified: this genuinely returns `nil` — not a hang or a crash —
when accessibility is unreachable**, exercised against a real, freshly
launched session bus with `org.a11y.Bus`'s D-Bus service-activation file
removed before ever touching it.

`isAccessibilityEnabled` reads `org.a11y.Status.IsEnabled` for diagnostics
only; this module never writes it (flipping it system-wide slows every
GTK/Qt app on the desktop). **Verified this is safe to leave alone for
GTK4 specifically**: a real GTK4 app registers on the a11y bus and emits
real focus/state signals regardless of `IsEnabled`'s value — confirmed both
with it left at its real-world default (`false`) and forced `true`, with
`gdbus`'s own `Properties.Get`/`Set`. (GTK3/Qt apps typically DO gate their
own AT-SPI bridge on this flag or the equivalent `toolkit-accessibility`
GSetting — untested here, per the port plan's own coverage note below.)

## `ATSPIFocusTracker`

```swift
public final class ATSPIFocusTracker: @unchecked Sendable {
  public init(connection: DBusConnection, readTimeout: Duration = .seconds(1))
  public func start()
  public func currentFocusedObject() -> (busName: String, objectPath: String)?
}
```

Tracks "which accessible currently has keyboard focus" by listening for
`org.a11y.atspi.Registry`'s `object:state-changed:focused` broadcasts (per
`at-spi2-core`'s own `Event.xml`), never by walking the accessibility tree
(too slow for a hotkey path). `start()` sends `RegisterEvent` +
`AddMatch`, then reads signals on a background thread; `currentFocusedObject()`
is a cheap, lock-protected read of the last one observed.

**One real, inherent limitation, verified against a live bus, not
theoretical:** a focus event that fires BEFORE this tracker's `AddMatch`
rule is registered on the bus is gone forever — D-Bus signals are not
queued for late subscribers, and there is no tree-walk fallback to recover
it. In practice this only affects the very first focus of the very first
window of an app that was already focused before Clipnest itself started —
`ATSPIFocusTracker.start()` runs once at Clipnest's own launch and stays
subscribed for the rest of the session, so any LATER focus change (the
representative case: the user switches to/inside an app while Clipnest is
already running) is caught reliably.

## `ATSPITextAccessor`

```swift
public struct ATSPITextAccessor: SelectedTextAccessing {
  public init(
    caller: any ATSPIObjectCalling,
    focusedObject: @escaping @Sendable () -> (busName: String, objectPath: String)?,
    timeout: Duration = ATSPIConstants.callTimeout,
    nextSerial: @escaping @Sendable () -> UInt32
  )
  public func readSelectedText() -> String?
  @discardableResult public func replaceSelectedText(with text: String) -> Bool
}
```

- **`readSelectedText()`** chains `Text.GetNSelections` → `Text.GetSelection`
  → `Text.GetText(start, end)`. Returns `nil` on no focus, no selection, or
  any call failing/timing out.
- **`replaceSelectedText(with:)`** reads the CURRENTLY selected text first
  (see below), then `EditableText.DeleteText(start, end)` +
  `EditableText.InsertText(position, text, length)` — **never
  `SetTextContents`**, whose documented semantics replace the entire
  document, which in anything but a single-field entry would destroy
  everything outside the selection.
- **Partial-edit safety:** `DeleteText` and `InsertText` are two
  independent D-Bus calls with no transaction wrapping them. If `InsertText`
  fails/times out AFTER `DeleteText` already succeeded, this method makes
  an unconditional best-effort attempt to re-insert the ORIGINAL text (read
  before the delete) back at the same position before reporting failure —
  a partially-applied edit (text silently erased, nothing put back) is a
  strictly worse outcome than the caller's clipboard fallback and is the
  one failure mode this method actively guards against, not just tolerates.
- **Write re-verification, not blind trust in a `true` reply (D97/D100):** a
  boolean `true` from `InsertText` only certifies the target app's
  `EditableText` handler ACCEPTED the call, the same way `AXError.success`
  certifies acceptance, not effect, on macOS. After a `true` reply, this
  method reads back `Text.GetText(selection.start, selection.start +
  scalarCount(text))` and compares it to `text`; a mismatch (or an
  unreadable range) is reported as `false` — a phantom insert. **This does
  NOT run the partial-edit rollback above.** That rollback fires from a
  KNOWN state (delete confirmed done, insert confirmed failed); a
  verified-but-suspicious insert is an UNKNOWN state, and re-inserting the
  original text on top of an unknown state risks duplicating content
  instead of recovering it — see `replaceSelectedText`'s doc comment for
  the full reasoning. No live AT-SPI phantom-write repro backs this
  specific mismatch case (unlike the macOS AX phantom-write bug it
  mirrors) — this is contract symmetry, not an observed defect.

### `InsertText`'s length argument is a BYTE count, not a character count

Per `at-spi2-core`'s own `EditableText.xml` (`<method name="InsertText">`,
confirmed against the real source): `position` is a character/scalar
offset, but `length` is documented as "the number of characters of text to
insert, **in bytes**." `UTF8OffsetConversion.utf8ByteCount(of:)` computes
this; `ATSPIRequests.insertText` always passes it, never `text.count`.
**Verified against a real GTK4 accessible with a real multi-byte string**
(`"héllo wörld"` — 11 characters, 13 UTF-8 bytes): the real `InsertText`
call captured off the live a11y bus carries `length: 13`, and the text
lands correctly in the target widget.

## Verified behavior (not assumed)

Everything above was previously "manual-verify only" — every file in this
subsystem said so in its own doc comment, and nothing here had ever run
against a real accessibility bus. It has now been proven end to end: a real
`at-spi2-core` bus, a real GTK4 window (two `GtkEntry`s), and the actual
production `SnippetExpander` (not a lower-level primitive) reading a real
selection, matching a real seeded snippet keyword, and replacing it in
place — confirmed by the target GTK4 app's own `notify::text` signal
firing with the correctly-replaced string, and by a clipboard sentinel set
before the run surviving byte-for-byte after it.

One real, load-bearing bug was found and fixed by this verification:
`Text.GetSelection`'s reply is **two separate top-level `int32` arguments**
(`GetSelection(selectionNum: i) -> (startOffset: i, endOffset: i)`, per its
own interface XML), not a single `(ii)` STRUCT. The previous parser assumed
the struct shape; a real `dbus-monitor` capture of a live `GetSelection`
call/reply shows `int32 7` followed by a SEPARATE `int32 13`, never nested.
The wrong assumption made `readSelectedText()`/`replaceSelectedText(with:)`
fail on literally every real call, unconditionally — the AT-SPI tier had a
0% real-world success rate before this fix, always silently falling through
to the clipboard tier regardless of which app was focused. The bug shipped
undetected because the existing unit test encoded the identical wrong
assumption as its canned reply (fixed alongside the production code — see
`Tests/ClipnestPlatformLinuxTests/ATSPIRequestsResponsesTests.swift` and
`ATSPITextAccessorTests.swift`).

**AT-SPI's `Text`/`EditableText` offsets are Unicode SCALAR (codepoint)
offsets — measured against a real bus, not assumed.** Two live probes
against a real GTK4 `GtkEntry` disambiguated this from the other
candidates: (1) an entry containing an astral emoji (`"a😀bcd"`) reported
`Text.CharacterCount == 5` and `GetText(1,2)` returned the WHOLE 4-byte
emoji as a single offset step — ruling out UTF-16 code units (which would
split the emoji's surrogate pair across two offsets, count 6) and UTF-8
bytes (count 8); (2) an entry containing a base+combining-mark sequence
(`"e" + U+0301`, one `Character`/grapheme, two scalars) reported
`CharacterCount == 6` for `"a" + "é" + "bcd"`, with `GetText(1,2)` and
`GetText(2,3)` returning the base letter and the combining mark
SEPARATELY — ruling out extended-grapheme-cluster counting. A `dbus-monitor`
capture of the live `EditableText.InsertText(position: 1, text: "😀Y",
length: 5)` call confirms the wire shape end to end: `CharacterCount`
advanced by exactly 2 (the scalar count of `"😀Y"`), and the immediate
`Text.GetText(1, 3)` read back `"😀Y"` byte-for-byte. This is the same unit
`UTF8OffsetConversion.scalarCount(of:)` computes and
`ATSPITextAccessor.replaceSelectedText`'s write re-verification (above)
relies on.

## Coverage

Realistic, not aspirational — worse than macOS's Accessibility API. GTK4
implements `Text`/`EditableText` fully and was verified for real (above).
GTK3/Qt apps typically need `toolkit-accessibility`/equivalent enabled
(often off by default) — not tested in this pass. Electron apps effectively
miss without `--force-renderer-accessibility`. Terminal emulators generally
implement neither interface at all — `DeleteText`/`InsertText` there fails
cleanly (this type reports `false`, `SnippetExpander` falls to the
clipboard tier), never a crash or a hang. This is why `SnippetExpander`'s
clipboard-fallback tier carries most real-world Linux traffic, same as
before this fix — this work makes the Accessibility-first tier actually
FIRE when it can, it doesn't change how often it CAN.

## Working example

```swift
// Composition root (LinuxAppEnvironment.makeSelectedTextAccessing()):
guard
  let sessionBusAddress = ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"],
  let a11yAddress = AccessibilityBusResolver.resolveAddress(sessionBusAddress: sessionBusAddress),
  let callConnection = DBusConnection.connect(address: a11yAddress, timeout: .seconds(1)),
  let signalConnection = DBusConnection.connect(address: a11yAddress, timeout: .seconds(1))
else {
  return NullSelectedTextAccessing()  // SnippetExpander falls straight to clipboard.
}

let focusTracker = ATSPIFocusTracker(connection: signalConnection)
focusTracker.start()
return ATSPITextAccessor(
  caller: callConnection, focusedObject: { focusTracker.currentFocusedObject() },
  nextSerial: { callConnection.allocateSerial() })
```
