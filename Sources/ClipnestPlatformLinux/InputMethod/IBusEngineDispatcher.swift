import Foundation

/// Every INBOUND request this app's `org.freedesktop.IBus.Factory`/
/// `org.freedesktop.IBus.Engine` objects can receive, decoded from the raw
/// `DBusMessage` the daemon hands them — IBus calls US (we register as an
/// engine), the reverse direction of every other D-Bus surface in this
/// codebase. Pure — no D-Bus I/O — mirroring
/// `ClipnestControlRequest`/`ClipnestControlReplies`'s identical split, so
/// dispatch decisions are directly unit-testable without a real bus
/// connection.
///
/// **Correctness requirement #2 (T-IBUS-WIRE): no force-unwraps, no
/// unhandled-message path.** `decode(_:)`'s switches are exhaustive with a
/// safe `.unknown`/`.malformed` default on every branch — a malformed or
/// unexpected call from the daemon must produce a safe reply, never a
/// crash. This is not a style preference here: during this feature's own
/// POC development, a real engine-registration bug crashed the process
/// and briefly left the GNOME session with NO global engine at all — the
/// user could not type. `IBusEngineMember`'s doc comment lists every real
/// `org.freedesktop.IBus.Engine` member (`SetCursorLocation`,
/// `ProcessHandWritingEvent`, `CancelHandWriting`, `PropertyShow`,
/// `PropertyHide`, `CandidateClicked`, `FocusInId`, `FocusOutId`,
/// `PageUp`, `PageDown`, `CursorUp`, `CursorDown`,
/// `PanelExtensionReceived`, `PanelExtensionRegisterKeys`) this module
/// does not implement — every one of them, and any interface/member ibus
/// might ever call that this app has never heard of at all (e.g. a stray
/// `org.freedesktop.DBus.Introspectable.Introspect` probe), decodes to
/// `.unknown` and gets a normal `UnknownMethod` D-Bus error reply, never a
/// force-unwrap or a silently dropped call.
///
/// This is a **pure protocol layer** (T-IBUS-WIRE, size M): no live
/// `DBusConnection`/socket code exists here, matching
/// `ClipnestControlDispatcher`'s own "extracted from the service so it's
/// constructible and testable WITHOUT a real `DBusConnection`" reasoning.
/// A future task wires a real GDBus-object-equivalent registration
/// (`RegisterComponent` -> daemon calls `CreateEngine` on our Factory ->
/// our Engine object starts receiving `IBusEngineMember` calls) around
/// this dispatcher, the same way `ClipnestControlService` wraps
/// `ClipnestControlDispatcher` — until then, every symbol here stays
/// internal to this module, matching `ATSPIRequests`/`ATSPIResponses`'
/// own "pure builders no other target references directly" convention;
/// that future task may need to widen a few of these to `public`, a
/// trivial, safe visibility-only change.
/// `public` (T-IBUS-CLIENT): `IBusCommitClient` (`ClipnestLinuxAppKit`)
/// decodes every real inbound message through `decode(_:)` directly on its
/// own registration-connection reader loop — the exact cross-module
/// widening this type's own doc comment anticipated ("a future task may
/// need to widen a few of these to public").
public enum IBusInboundRequest: Equatable {
  /// `org.freedesktop.IBus.Factory.CreateEngine(name: s) -> (o)` — the
  /// ONE inbound member with a real return VALUE (every `Engine` member
  /// below just acknowledges with an empty reply, except
  /// `processKeyEvent`). See `IBusEngineDispatcher.onCreateEngine`'s doc
  /// comment for how the reply's object path gets built.
  case createEngine(engineName: String)

  case focusIn
  case focusOut
  case enable
  case disable
  case reset
  case setCapabilities(IBusCapabilities)
  /// `ProcessKeyEvent(keyval: u, keycode: u, state: u) -> (b)`. See
  /// `IBusEngineDispatcher.handle(_:message:)`'s own doc comment for
  /// correctness requirement #1 — decoding this case carries no risk by
  /// itself; the risk is entirely in what gets REPLIED, which this enum
  /// has no say in.
  case processKeyEvent(keyval: UInt32, keycode: UInt32, state: UInt32)
  /// `SetSurroundingText(text: v, cursor_pos: u, anchor_pos: u)`.
  /// `cursorPos`/`anchorPos` are UNICODE CHARACTER (codepoint) offsets
  /// into `text.text` — see `IBusResponses.parseIBusText(_:)`'s doc
  /// comment for the text decoding, and `IBusCapabilities.surroundingText`
  /// for whether this case reliably arrives at all.
  ///
  /// **Unit confirmed from upstream client code, curl'd 2026-09-14, not
  /// inferred from ASCII-only behavior (T-ATSPI1/D95's exact failure
  /// mode):** `client/gtk2/ibusimcontext.c`'s
  /// `ibus_im_context_set_surrounding_with_selection` computes these two
  /// values with `g_utf8_strlen(text, cursor_index)` (a CHARACTER count
  /// of the UTF-8 prefix up to `cursor_index` BYTES) and
  /// `g_utf8_strlen(text, cursor_index + selection_length)` for the
  /// anchor — `g_utf8_strlen` counts Unicode characters, never bytes,
  /// UTF-16 units, or grapheme clusters. `client/wayland/ibuswaylandim.c`
  /// does the equivalent conversion with `g_utf8_pointer_to_offset`.
  /// Ibus's own doc-comment on the argument (`src/ibusengine.c`'s
  /// `set-surrounding-text` signal) calls both "position ... in
  /// characters," matching this independently.
  case setSurroundingText(text: IBusText, cursorPos: UInt32, anchorPos: UInt32)
  /// `PropertyActivate(name: s, state: u)`.
  case propertyActivate(name: String, state: UInt32)

  /// A recognized member on a recognized interface, but with a body shape
  /// this dispatcher can't parse (e.g. `SetCapabilities` missing its
  /// `caps` argument, or carrying the wrong D-Bus type for it) — maps to
  /// `InvalidArgs`, not `UnknownMethod`. Mirrors
  /// `ClipnestControlRequest.malformed`'s identical distinction.
  case malformed
  /// An interface/member this dispatcher doesn't implement at all — maps
  /// to `UnknownMethod`. Covers both a genuinely unknown interface AND
  /// every real `org.freedesktop.IBus.Engine` member this module doesn't
  /// enumerate (see this enum's own top-level doc comment).
  case unknown

  /// Decodes exactly one incoming method call. `nil` for anything that
  /// isn't a method call at all (a reply/signal this connection happened
  /// to read) — mirrors `ClipnestControlRequest.decode`'s identical
  /// contract, including what a caller should do with `nil` (nothing;
  /// ignore it, don't reply).
  public static func decode(_ message: DBusMessage) -> IBusInboundRequest? {
    guard message.type == .methodCall else { return nil }

    switch message.interface {
    case IBusInterface.factory:
      return decodeFactoryMember(message)
    case IBusInterface.engine:
      return decodeEngineMember(message)
    default:
      return .unknown
    }
  }

  private static func decodeFactoryMember(_ message: DBusMessage) -> IBusInboundRequest {
    switch message.member {
    case IBusFactoryMember.createEngine:
      guard case .string(let name)? = message.body.first else { return .malformed }
      return .createEngine(engineName: name)
    default:
      return .unknown
    }
  }

  private static func decodeEngineMember(_ message: DBusMessage) -> IBusInboundRequest {
    switch message.member {
    case IBusEngineMember.focusIn: return .focusIn
    case IBusEngineMember.focusOut: return .focusOut
    case IBusEngineMember.enable: return .enable
    case IBusEngineMember.disable: return .disable
    case IBusEngineMember.reset: return .reset
    case IBusEngineMember.setCapabilities:
      guard case .uint32(let caps)? = message.body.first else { return .malformed }
      return .setCapabilities(IBusCapabilities(rawValue: caps))
    case IBusEngineMember.processKeyEvent:
      guard message.body.count == 3, case .uint32(let keyval) = message.body[0],
        case .uint32(let keycode) = message.body[1], case .uint32(let state) = message.body[2]
      else { return .malformed }
      return .processKeyEvent(keyval: keyval, keycode: keycode, state: state)
    case IBusEngineMember.setSurroundingText:
      guard message.body.count == 3, let text = IBusResponses.parseIBusText(message.body[0]),
        case .uint32(let cursorPos) = message.body[1],
        case .uint32(let anchorPos) = message.body[2]
      else { return .malformed }
      return .setSurroundingText(text: text, cursorPos: cursorPos, anchorPos: anchorPos)
    case IBusEngineMember.propertyActivate:
      guard message.body.count == 2, case .string(let name) = message.body[0],
        case .uint32(let state) = message.body[1]
      else { return .malformed }
      return .propertyActivate(name: name, state: state)
    default:
      return .unknown
    }
  }
}

/// Pure builders for every reply `IBusEngineDispatcher` ever sends —
/// separated out for the same testability reason
/// `IBusInboundRequest.decode` is, mirroring `ClipnestControlReplies`.
enum IBusEngineReplies {
  static func empty(replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender)
  }

  /// `CreateEngine(name) -> (o)` — the one inbound member with a real
  /// return value.
  static func createEngine(objectPath: String, replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender,
      body: [.objectPath(objectPath)])
  }

  /// `ProcessKeyEvent(...) -> (b)` — **ALWAYS `false`, with no parameter
  /// to say otherwise.** This is correctness requirement #1
  /// (T-IBUS-WIRE), enforced at the TYPE level rather than by convention:
  /// giving this function a `consumed: Bool` parameter would let some
  /// future edit to `IBusEngineDispatcher.handle(_:message:)` pass `true`
  /// with the compiler's full blessing — exactly the shape
  /// coding-standards.md's "a function that cannot express X will always
  /// be forced to lie" reasoning (`outcome=replaced`) argues against, just
  /// mirrored: here the danger is a silently ADDED capability (eating a
  /// real keystroke), not a silently missing one. This app is the global
  /// IBus engine for only a few tens of milliseconds per expansion; a real
  /// keystroke landing in that window MUST pass through untouched, or it
  /// is silently eaten from the user's typing — see
  /// `IBusEngineDispatcher.handle(_:message:)`'s `.processKeyEvent` case
  /// for where this is called, and
  /// `IBusEngineDispatcherTests.processKeyEventNeverConsumed*` for the
  /// regression tests.
  static func processKeyEventNeverConsumed(replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender,
      body: [.boolean(false)])
  }

  static func unknownMethod(replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .error, serial: 0, errorName: IBusErrorName.unknownMethod,
      replySerial: message.serial, destination: message.sender,
      body: [.string("No such member '\(message.member ?? "?")' on '\(message.interface ?? "?")'")]
    )
  }

  static func invalidArgs(replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .error, serial: 0, errorName: IBusErrorName.invalidArgs,
      replySerial: message.serial, destination: message.sender,
      body: [.string("Invalid arguments for '\(message.member ?? "?")'")])
  }
}

/// Pure request -> handler-closure -> reply routing for
/// `org.freedesktop.IBus.Factory`/`org.freedesktop.IBus.Engine` —
/// mirrors `ClipnestControlDispatcher`'s identical role, extracted so it's
/// constructible and testable without a real `DBusConnection`.
///
/// **Every closure is a REQUIRED constructor parameter, none defaulted —
/// deliberately, NOT matching `ClipnestControlDispatcher`'s own
/// defaulted-`{ }` closures.** coding-standards.md's own top rule ("a
/// cross-platform seam MUST NOT have a silent default") names the exact
/// bug class a defaulted no-op closure produces
/// (`PickerViewModel.presentSnippetEditor` cost the ENTIRE Linux port
/// before anyone noticed) and explicitly says: "When you genuinely need a
/// no-op fallback ... make it explicit at the call site ... never a
/// default the caller can forget." `onCreateEngine` in particular has no
/// safe no-op: an unwired factory would silently fail to ever produce a
/// working engine, with every earlier step (`RegisterComponent`,
/// `SetGlobalEngine`) still reporting success. Requiring every closure at
/// `init` makes a forgotten wiring a BUILD ERROR at the call site, not a
/// silently-dead feature discovered by accident later.
/// `public` (T-IBUS-CLIENT): the live connection layer (`IBusCommitClient`,
/// `ClipnestLinuxAppKit`) constructs one of these and drives it from its
/// own registration-connection reader loop — the cross-module widening
/// this type's own doc comment anticipated.
public final class IBusEngineDispatcher {
  public var onFocusIn: () -> Void
  public var onFocusOut: () -> Void
  public var onEnable: () -> Void
  public var onDisable: () -> Void
  public var onReset: () -> Void
  public var onSetCapabilities: (IBusCapabilities) -> Void
  /// `Void`-returning by design — see `IBusEngineReplies
  /// .processKeyEventNeverConsumed(replyingTo:)`'s doc comment: this
  /// closure exists purely for OBSERVING/reacting to a raw key event
  /// (e.g. diagnostics), never for deciding whether it was consumed. It
  /// cannot influence `handle(_:message:)`'s reply even in principle,
  /// because its return type carries no information back.
  public var onProcessKeyEvent: (_ keyval: UInt32, _ keycode: UInt32, _ state: UInt32) -> Void
  public var onSetSurroundingText:
    (_ text: IBusText, _ cursorPos: UInt32, _ anchorPos: UInt32) -> Void
  public var onPropertyActivate: (_ name: String, _ state: UInt32) -> Void
  /// Returns the newly-created engine's object path (e.g. via
  /// `IBusPath.engine(id:)` with a freshly-allocated id) — this dispatcher
  /// holds no state of its own to allocate one from (it is deliberately
  /// pure/stateless otherwise, matching `ClipnestControlDispatcher`), so
  /// ID allocation is entirely this closure's owner's responsibility.
  public var onCreateEngine: (_ engineName: String) -> String

  public init(
    onFocusIn: @escaping () -> Void,
    onFocusOut: @escaping () -> Void,
    onEnable: @escaping () -> Void,
    onDisable: @escaping () -> Void,
    onReset: @escaping () -> Void,
    onSetCapabilities: @escaping (IBusCapabilities) -> Void,
    onProcessKeyEvent: @escaping (_ keyval: UInt32, _ keycode: UInt32, _ state: UInt32) -> Void,
    onSetSurroundingText: @escaping (
      _ text: IBusText, _ cursorPos: UInt32, _ anchorPos: UInt32
    ) -> Void,
    onPropertyActivate: @escaping (_ name: String, _ state: UInt32) -> Void,
    onCreateEngine: @escaping (_ engineName: String) -> String
  ) {
    self.onFocusIn = onFocusIn
    self.onFocusOut = onFocusOut
    self.onEnable = onEnable
    self.onDisable = onDisable
    self.onReset = onReset
    self.onSetCapabilities = onSetCapabilities
    self.onProcessKeyEvent = onProcessKeyEvent
    self.onSetSurroundingText = onSetSurroundingText
    self.onPropertyActivate = onPropertyActivate
    self.onCreateEngine = onCreateEngine
  }

  public func handle(_ request: IBusInboundRequest, message: DBusMessage) -> DBusMessage? {
    switch request {
    case .createEngine(let engineName):
      let objectPath = onCreateEngine(engineName)
      return IBusEngineReplies.createEngine(objectPath: objectPath, replyingTo: message)
    case .focusIn:
      onFocusIn()
      return IBusEngineReplies.empty(replyingTo: message)
    case .focusOut:
      onFocusOut()
      return IBusEngineReplies.empty(replyingTo: message)
    case .enable:
      onEnable()
      return IBusEngineReplies.empty(replyingTo: message)
    case .disable:
      onDisable()
      return IBusEngineReplies.empty(replyingTo: message)
    case .reset:
      onReset()
      return IBusEngineReplies.empty(replyingTo: message)
    case .setCapabilities(let capabilities):
      onSetCapabilities(capabilities)
      return IBusEngineReplies.empty(replyingTo: message)
    case .processKeyEvent(let keyval, let keycode, let state):
      onProcessKeyEvent(keyval, keycode, state)
      // Correctness requirement #1 (T-IBUS-WIRE) — see
      // `IBusEngineReplies.processKeyEventNeverConsumed(replyingTo:)`'s
      // doc comment for why this is the ONLY call site and why that
      // function takes no `consumed` parameter at all.
      return IBusEngineReplies.processKeyEventNeverConsumed(replyingTo: message)
    case .setSurroundingText(let text, let cursorPos, let anchorPos):
      onSetSurroundingText(text, cursorPos, anchorPos)
      return IBusEngineReplies.empty(replyingTo: message)
    case .propertyActivate(let name, let state):
      onPropertyActivate(name, state)
      return IBusEngineReplies.empty(replyingTo: message)
    case .malformed:
      return IBusEngineReplies.invalidArgs(replyingTo: message)
    case .unknown:
      return IBusEngineReplies.unknownMethod(replyingTo: message)
    }
  }
}
