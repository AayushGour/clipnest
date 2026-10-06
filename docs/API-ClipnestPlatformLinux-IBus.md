# ClipnestPlatformLinux — IBus protocol layer reference

Linux-only (`#if os(Linux)`, see `Package.swift`). This page documents
`Sources/ClipnestPlatformLinux/InputMethod/**` — the D-Bus wire protocol for
IBus (`org.freedesktop.IBus`), the transport behind snippet expansion's
**tier 2** on GNOME Wayland (see `.claude/project-context.md`'s `D-IBUS-1..6`
decision block). It does not document `ClipnestPlatformLinux`'s other
subsystems — see
[`docs/API-ClipnestPlatformLinux.md`](API-ClipnestPlatformLinux.md) for the
AT-SPI (tier 1) subsystem this one sits alongside.

**Status: pure protocol layer (T-IBUS-WIRE), now driven by a live connection
layer (T-IBUS-CLIENT).** Every type below is still builders/parsers/dispatch
logic, unit-tested without a real bus — this page documents the pure
protocol only. The live-connection layer (`IBusCommitClient`, analogous to
how `ATSPITextAccessor`/`ATSPIFocusTracker` wrap `ATSPIRequests`/
`ATSPIResponses`, or how `ShellHelperClient` wraps `ShellHelperRequests`/
`ShellHelperResponses`) now exists in `ClipnestLinuxAppKit` — see
[`docs/API-ClipnestLinuxAppKit.md`](API-ClipnestLinuxAppKit.md#ibuscommitclient--the-ibus-commit-tier-live-connection-t-ibus-client)
for address resolution, connecting, `RegisterComponent`, the global-engine
switch/restore crash-safety state machine (`D-IBUS-3`), and the real
`IBusEngineDispatcher` receive loop. Several symbols below were widened from
`internal` to `public` for that cross-module use — each widening site
carries its own "T-IBUS-CLIENT" doc-comment note; the full list is in that
other page's own "Cross-module visibility" section. `IBusAddressResolution`
also gained `resolveWithDaemonPID`/`parseDaemonPID` (T-IBUS-PIDLIVE, closed
by T-IBUS-CLIENT) — see that section below.

## Contents
- [The headline finding: the keyword read does not need the Shell extension](#the-headline-finding-the-keyword-read-does-not-need-the-shell-extension)
- [`IBusAddressResolution`](#ibusaddressresolution)
- [`IBusNames` / `IBusCapabilities` / `IBusText`](#ibusnames--ibuscapabilities--ibustext)
- [`IBusRequests`](#ibusrequests)
- [`IBusResponses`](#ibusresponses)
- [`IBusEngineDispatcher`](#ibusenginedispatcher)
- [Unit conventions (cited from upstream, not assumed)](#unit-conventions-cited-from-upstream-not-assumed)
- [What is NOT settled by this task](#what-is-not-settled-by-this-task)

## The headline finding: the keyword read does not need the Shell extension

`D-IBUS-5` (`.claude/project-context.md`) was OPEN: the architect's original
design read the pre-expansion keyword via
`ShellHelperClient.readClipboard(selection: .primary)`, which requires the
GNOME Shell extension — reintroducing, for the READ side, exactly the
extension dependency IBus's commit-based WRITE was meant to remove.

**Resolved, from ibus's own upstream C source (`github.com/ibus/ibus`,
curl'd directly — `src/ibusengine.c`, `client/gtk2/ibusimcontext.c` — not
inferred or assumed):**

- An engine calls `ibus_engine_get_surrounding_text()`, which emits a
  NULLARY `RequireSurroundingText` D-Bus signal — `IBusRequests
  .requireSurroundingText(objectPath:serial:)` builds this message.
- GTK's own IBus IM context (`ibusimcontext.c`) advertises
  `IBUS_CAP_SURROUNDING_TEXT` on every context by default, and answers a
  `RequireSurroundingText` by emitting the focused widget's `retrieve
  -surrounding` GTK signal; if the widget answers, GTK sends a REAL
  `SetSurroundingText(text: v, cursor_pos: u, anchor_pos: u)` call back —
  `IBusEngineDispatcher` decodes this as
  `.setSurroundingText(text:cursorPos:anchorPos:)`.
- This is a genuine, synchronous protocol round trip, not silent best-effort
  — `GtkEntry`/`GtkTextView` and VTE terminals (already confirmed
  end-to-end on the VM by this feature's own POC) implement `retrieve
  -surrounding` for real.
- **The one real caveat, also confirmed from source, not glossed over:**
  the capability bit is OPTIMISTIC. GTK sets it before knowing whether the
  specific focused widget can actually answer, and only discovers a
  failure REACTIVELY (the widget's `retrieve-surrounding` signal comes back
  unhandled) — at which point GTK logs a warning and permanently revokes
  the bit for that context. A caller receiving `SetCapabilities` with
  `.surroundingText` set should treat it as "the toolkit believes this is
  possible," not "this exact control has already proven it."

**Practical consequence for the layer above this one:** a caller can drive
the whole read with `RequireSurroundingText` + wait for `SetSurroundingText`
(with a short timeout, since the round trip is NOT guaranteed to arrive —
see the caveat above) instead of ever calling `ShellHelperClient
.readClipboard`. Whether GTK4 (as opposed to the GTK2 `ibusimcontext.c`
actually read) and Qt implement the identical contract is flagged under
[What is NOT settled](#what-is-not-settled-by-this-task) below — inference
from the GTK2 source and the architect's own POC, not independently
re-verified against GTK4/Qt source by this task.

## `IBusAddressResolution`

`Sources/ClipnestPlatformLinux/InputMethod/IBusAddress.swift` (T-IBUS-ADDR,
extended by T-IBUS-CLIENT for the daemon-PID pairing below). Resolves
IBus's private-bus address — `IBUS_ADDRESS` env var first, else the
socket-address file under `~/.config/ibus/bus/` (or `$XDG_RUNTIME_DIR`'s
equivalent, tried second — the real daemon on this project's VM used the
config-dir path, confirming which candidate is live). Pure — no socket I/O,
env and file-read are both injected closures.

```swift
public struct IBusResolvedAddress: Equatable, Sendable {
  public var address: String
  public var daemonPID: Int32?   // nil for the env-var path, or a file with no PID line
}

public enum IBusAddressResolution {
  public static func resolve(environment: [String: String], readFile: (String) -> String?) -> String?
  public static func resolveWithDaemonPID(
    environment: [String: String], readFile: (String) -> String?
  ) -> IBusResolvedAddress?
}
```

**T-IBUS-PIDLIVE (closed by T-IBUS-CLIENT):** upstream `ibus_get_address()`
also reads an `IBUS_DAEMON_PID=` line from the SAME socket file and
discards the address unless `kill(pid, 0)` proves that daemon is still
alive — a real process-liveness syscall, deliberately out of scope for
this pure-logic module. `resolveWithDaemonPID` PARSES that PID (still pure,
no syscall) and pairs it with the address; `IBusCommitClient
.resolveAndConnect` (`ClipnestLinuxAppKit`) is the one caller that actually
calls `kill(pid, 0)` and discards a stale address before ever dialing it.
`resolve(environment:readFile:)` is unchanged for every existing caller —
it's now a thin wrapper over `resolveWithDaemonPID` that drops the PID.

## `IBusNames` / `IBusCapabilities` / `IBusText`

Every bus name / object path / interface / member string this module uses —
see the file's own doc comments for the exact upstream citation (file +
function) behind each one. Two value types worth knowing about directly:

```swift
struct IBusCapabilities: OptionSet, Equatable, Sendable {
  let rawValue: UInt32
  static let preeditText: IBusCapabilities
  static let auxiliaryText: IBusCapabilities
  static let lookupTable: IBusCapabilities
  static let focus: IBusCapabilities
  static let property: IBusCapabilities
  static let surroundingText: IBusCapabilities   // IBUS_CAP_SURROUNDING_TEXT, 1<<5 — see the finding above
  static let osk: IBusCapabilities
  static let syncProcessKey: IBusCapabilities
}

struct IBusText: Equatable, Sendable {
  var text: String   // presentation attributes (IBusAttrList) are never surfaced — see its doc comment
}
```

## `IBusRequests`

Pure builders for every message this app sends: `org.freedesktop.IBus`
(bus/daemon) method calls, plus the signals an engine instance emits.

```swift
enum IBusRequests {
  static func registerComponent(_ component: IBusComponentDescriptor, serial: UInt32) -> DBusMessage
  static func setGlobalEngine(name: String, serial: UInt32) -> DBusMessage
  static func getGlobalEngine(serial: UInt32) -> DBusMessage
  static func currentInputContext(serial: UInt32) -> DBusMessage

  static func commitText(_ text: IBusText, objectPath: String, serial: UInt32) -> DBusMessage
  static func deleteSurroundingText(
    offsetFromCursor: Int32, characterCount: UInt32, objectPath: String, serial: UInt32
  ) -> DBusMessage
  static func requireSurroundingText(objectPath: String, serial: UInt32) -> DBusMessage

  static func serializedText(_ text: IBusText) -> DBusValue   // shared with IBusResponses.parseIBusText
}
```

`IBusComponentDescriptor`/`IBusEngineDescriptor` are the plain data structs
`registerComponent(_:serial:)` serializes — field order is load-bearing and
cited verbatim from `ibus_component_serialize`/`ibus_engine_desc_serialize`
in each type's own doc comment.

## `IBusResponses`

Pure parsers for what comes back from `IBusRequests`' bus calls, plus the
shared `IBusText` decoder `IBusEngineDispatcher` reuses for inbound
`SetSurroundingText`:

```swift
enum IBusResponses {
  static func isSuccessReply(_ message: DBusMessage) -> Bool
  static func parseGetGlobalEngineReply(_ message: DBusMessage) -> String?
  static func parseCurrentInputContextReply(_ message: DBusMessage) -> String?
  static func parseIBusText(_ value: DBusValue) -> IBusText?
}
```

## `IBusEngineDispatcher`

Pure request -> handler-closure -> reply routing for
`org.freedesktop.IBus.Factory`/`org.freedesktop.IBus.Engine` — IBus calls
**this app**, the reverse direction of every other D-Bus surface in this
codebase. Mirrors `ClipnestControlDispatcher`.

```swift
enum IBusInboundRequest: Equatable {
  case createEngine(engineName: String)
  case focusIn, focusOut, enable, disable, reset
  case setCapabilities(IBusCapabilities)
  case processKeyEvent(keyval: UInt32, keycode: UInt32, state: UInt32)
  case setSurroundingText(text: IBusText, cursorPos: UInt32, anchorPos: UInt32)
  case propertyActivate(name: String, state: UInt32)
  case malformed   // recognized member, unparseable body -> InvalidArgs
  case unknown     // unrecognized interface/member -> UnknownMethod, never a crash

  static func decode(_ message: DBusMessage) -> IBusInboundRequest?   // nil for a non-method-call
}

final class IBusEngineDispatcher {
  // Every closure below is a REQUIRED init parameter, none defaulted — see
  // the class's own doc comment for why (coding-standards.md's no-silent-
  // default rule, applied to a D-Bus dispatch seam this time).
  init(
    onFocusIn: @escaping () -> Void,
    onFocusOut: @escaping () -> Void,
    onEnable: @escaping () -> Void,
    onDisable: @escaping () -> Void,
    onReset: @escaping () -> Void,
    onSetCapabilities: @escaping (IBusCapabilities) -> Void,
    onProcessKeyEvent: @escaping (_ keyval: UInt32, _ keycode: UInt32, _ state: UInt32) -> Void,
    onSetSurroundingText: @escaping (_ text: IBusText, _ cursorPos: UInt32, _ anchorPos: UInt32) -> Void,
    onPropertyActivate: @escaping (_ name: String, _ state: UInt32) -> Void,
    onCreateEngine: @escaping (_ engineName: String) -> String   // returns the new engine's object path
  )
  func handle(_ request: IBusInboundRequest, message: DBusMessage) -> DBusMessage?
}
```

**Correctness requirement #1 — `ProcessKeyEvent` unconditionally reports
NOT consumed.** `onProcessKeyEvent` is `Void`-returning by design: it cannot
influence the reply even in principle. `handle(_:message:)`'s
`.processKeyEvent` case always replies via `IBusEngineReplies
.processKeyEventNeverConsumed(replyingTo:)`, a function with NO `consumed`
parameter at all — enforced at the type level, not by convention, because
this app is the global IBus engine for only a few tens of milliseconds per
expansion and a real keystroke landing in that window must pass through
untouched, or it is silently eaten from the user's typing. See
`IBusEngineDispatcherTests.processKeyEventNeverConsumed*` for the regression
tests (including one that varies the raw modifier `state` bitmask, up to
Super+Shift held, to pin that no state ever changes the answer).

**Correctness requirement #2 — no force-unwraps, no unhandled-message
path.** `IBusInboundRequest.decode`'s switches are exhaustive with a safe
`.unknown`/`.malformed` default on every branch — confirmed by test against
every real `org.freedesktop.IBus.Engine` member this module doesn't
implement (`SetCursorLocation`, `ProcessHandWritingEvent`,
`CancelHandWriting`, `PropertyShow`, `PropertyHide`, `CandidateClicked`,
`FocusInId`, `FocusOutId`, `PageUp`, `PageDown`, `CursorUp`, `CursorDown`,
`PanelExtensionReceived`, `PanelExtensionRegisterKeys`) and against an
entirely unrelated interface (e.g. a stray `Introspectable` probe) — both
degrade to `UnknownMethod`, never a crash. This mirrors a real incident from
this feature's own POC: an engine-registration bug crashed the engine
process during development and briefly left the GNOME session with NO
global engine at all — the user could not type.

## Unit conventions (cited from upstream, not assumed)

- **`SetSurroundingText(text, cursor_pos, anchor_pos)`** — `cursor_pos`/
  `anchor_pos` are UNICODE CHARACTER (codepoint) offsets into `text`, per
  `src/ibusengine.c`'s own introspection XML plus `client/gtk2
  /ibusimcontext.c`'s `ibus_im_context_set_surrounding_with_selection`,
  which computes them with `g_utf8_strlen` (a character count, never a byte
  or UTF-16-unit count) before sending.
- **`DeleteSurroundingText(offset_from_cursor, nchars)`** — both are
  UNICODE CHARACTER (UCS-4 codepoint) counts, confirmed by the REAL deletion
  arithmetic in `ibus_engine_delete_surrounding_text` (`src/ibusengine.c`):
  it converts the cached surrounding text to UCS-4
  (`g_utf8_to_ucs4_fast`) and indexes/`memmove`s over that `gunichar` array
  directly — never touching the UTF-8 byte buffer for the cut itself. This
  is the same POC's `delete_surrounding_text(-9, 9)` call on a 9-character
  ASCII keyword — which, being ASCII, could not by itself distinguish UTF-8
  bytes / UTF-16 units / scalars / graphemes (all four counts coincide for
  ASCII). The unit above comes from the deletion arithmetic itself, not
  from that single ASCII trial.
- **`CommitText(text)` / the `IBusText` wire tuple** — `(s a{sv} s v)`:
  type-name string (`"IBusText"`), an empty attachments dict, the text
  content, and a variant-wrapped (empty) `IBusAttrList`. Chained verbatim
  from `ibus_serializable_serialize_object` (`src/ibusserializable.c`),
  `ibus_serializable_real_serialize` (same file, the base class), and
  `ibus_text_serialize` (`src/ibustext.c`) — see `IBusRequests
  .serializedText(_:)`'s doc comment for the full three-function citation
  trail.

## What is NOT settled by this task

Named explicitly, not silently assumed:

- **GTK4's IM context implementation was not independently read.** The
  surrounding-text finding above cites GTK2's `ibusimcontext.c`; this
  feature's own POC exercised GTK4 apps (`gnome-text-editor`) successfully
  for the COMMIT side, but this task did not separately fetch and read
  GTK4's own (structurally different, GTK4 ships its own IM module
  rewrite) surrounding-text wiring to confirm it matches GTK2's contract
  exactly.
- **Qt's surrounding-text support is inference, not independently
  verified** by this task against Qt's own source — carried over from the
  architect's original framing.
- **Whether a real daemon reliably delivers `RequireSurroundingText` ->
  `SetSurroundingText` within a useful time budget** is untested here (no
  live socket code in this task) — the live-connection layer needs its own
  timeout/negative-result handling for the case a widget's capability bit
  gets revoked mid-session (see the caveat above).
- ~~**`RegisterComponent`'s exact required fields**~~ — **SETTLED by
  T-IBUS-CLIENT**: verified live against a real `ibus-daemon` (1.5.29-rc2,
  VM), 3/3 clean runs — a component with empty `homepage`/`exec`/
  `textdomain` registers successfully, exactly as this layer's builder
  allows.

## Also settled by T-IBUS-CLIENT (measured, not this task's own scope)

Two more design questions this protocol layer's own doc comments left
open, now measured against a real daemon by the live-connection layer —
full detail in
[`docs/API-ClipnestLinuxAppKit.md`](API-ClipnestLinuxAppKit.md#ibuscommitclient--the-ibus-commit-tier-live-connection-t-ibus-client):

- **The two-connection split (D-IBUS-4) does not deadlock** — verified with
  a raw two-connection probe against real `ibus-daemon` traffic (not
  libibus's own GI sync-call wrapper), 3/3 clean runs, zero timeouts.
- **`FocusIn` arrives fast and reliably** (~1ms after `SetGlobalEngine`,
  3/3 runs) — but with a real caveat, also measured rather than assumed:
  it fired even with no specific GUI text field focused, so it confirms
  "the daemon bound our engine to SOME current input context," not "a
  receptive text-editable widget is ready" — see `IBusCommitOutcome`'s own
  doc comment for why the outcome is `.committedUnconfirmed`, never
  `.replaced`, either way.

Still open, unchanged by this task: GTK4's own IM context implementation
(T-IBUS-WIRE's own item above), Qt's surrounding-text support, and whether
`RequireSurroundingText`/`SetSurroundingText` round-trips reliably — none
of those are exercised by the delete+commit path T-IBUS-CLIENT built.
