import Foundation

/// Every IBus D-Bus bus name, object path, interface name, and member name
/// this module ever sends or receives — kept in ONE place per
/// coding-standards.md's "no magic strings" rule, mirroring
/// `ShellHelperNames.swift`'s convention of naming the exact upstream
/// source each string is verbatim from.
///
/// This app is BOTH a CLIENT of `org.freedesktop.IBus` (the daemon; calls
/// `RegisterComponent`/`SetGlobalEngine`/`GetGlobalEngine`/
/// `CurrentInputContext` — see `IBusRequests`) AND a SERVER on
/// `org.freedesktop.IBus.Factory`/`org.freedesktop.IBus.Engine` (the
/// daemon calls THIS app back on those — see `IBusEngineDispatcher`), the
/// same "client of one interface, server of another" shape
/// `ShellHelperName` (client of the Shell extension) / `ClipnestControlName`
/// (server of this app's own control interface) already split across two
/// files for the GNOME Shell integration.
///
/// **T-IBUS-WIRE (2026-09-14): every string/shape below was read directly
/// off ibus's own upstream C source** (`github.com/ibus/ibus`, curl'd
/// live rather than assumed/guessed) — `src/ibusshare.h` for the bus
/// names/paths/interfaces, `bus/ibusimpl.c` + `src/ibusfactory.c` +
/// `src/ibusengine.c` for the `introspection_xml` each method/signal is
/// declared in (or, for `DeleteSurroundingText`/`RequireSurroundingText`,
/// conspicuously NOT declared in — see `IBusEngineSignal`'s own doc
/// comment). This is a **pure protocol layer** — no live `DBusConnection`/
/// socket code exists yet in this module for IBus (that is a follow-up
/// task); see `IBusEngineDispatcher.swift`'s own doc comment for exactly
/// what is and isn't covered.
enum IBusBusName {
  /// `IBUS_SERVICE_IBUS` (`src/ibusshare.h`) — the daemon's well-known bus
  /// name.
  static let daemon = "org.freedesktop.IBus"
}

public enum IBusPath {
  /// `IBUS_PATH_IBUS` (`src/ibusshare.h`) — the main `org.freedesktop.IBus`
  /// object's path; every `IBusBusMember` call targets this.
  static let bus = "/org/freedesktop/IBus"

  /// `IBUS_PATH_FACTORY` (`src/ibusshare.h`) — the FIXED path every ibus
  /// engine process registers its `org.freedesktop.IBus.Factory` object
  /// at, confirmed against `ibus_factory_new`'s own `g_object_new(...,
  /// "object-path", IBUS_PATH_FACTORY, ...)` in `src/ibusfactory.c` — a
  /// single well-known path shared by every engine process, unlike the
  /// per-instance engine objects it creates (see `engine(id:)` below).
  static let factory = "/org/freedesktop/IBus/Factory"

  /// The object-path PATTERN `IBus.Factory.CreateEngine`'s own real
  /// implementation uses for every engine instance it creates —
  /// `g_strdup_printf("/org/freedesktop/IBus/Engine/%d", id)` in
  /// `bus_factory_create_engine` (`src/ibusfactory.c`), `id` a per-factory
  /// running counter. Exposed as a pure function (not a stored constant)
  /// because the numeric suffix is instance-specific; ID ALLOCATION itself
  /// is deliberately NOT this module's concern (no live state exists
  /// here) — `IBusEngineDispatcher.onCreateEngine`'s doc comment explains
  /// why that closure, not this function, owns producing the real path.
  /// `public` (T-IBUS-CLIENT): this is the one symbol from this pure
  /// protocol layer the live connection layer (`IBusCommitClient`,
  /// `ClipnestLinuxAppKit`) directly calls — see this function's own doc
  /// comment above for why ID allocation, not path construction, is that
  /// caller's job.
  public static func engine(id: Int) -> String {
    "/org/freedesktop/IBus/Engine/\(id)"
  }
}

enum IBusInterface {
  /// `IBUS_INTERFACE_IBUS` (`src/ibusshare.h`) — the daemon's main
  /// interface; `RegisterComponent`/`SetGlobalEngine`/`GetGlobalEngine`/
  /// `CurrentInputContext` all live here (`bus/ibusimpl.c`'s own
  /// `introspection_xml`, curl'd 2026-09-14).
  static let bus = "org.freedesktop.IBus"

  /// `IBUS_INTERFACE_FACTORY` (`src/ibusshare.h`) — implemented by the
  /// ENGINE PROCESS (this app), not the daemon; the daemon calls
  /// `CreateEngine` on it (`src/ibusfactory.c`'s own `introspection_xml`:
  /// `<interface name='org.freedesktop.IBus.Factory'><method
  /// name='CreateEngine'>...`).
  static let factory = "org.freedesktop.IBus.Factory"

  /// `IBUS_INTERFACE_ENGINE` (`src/ibusshare.h`) — implemented by EACH
  /// engine instance this app's factory creates; the daemon invokes every
  /// member in `IBusEngineMember` on it (`src/ibusengine.c`'s own
  /// `introspection_xml`).
  static let engine = "org.freedesktop.IBus.Engine"
}

/// `org.freedesktop.IBus` (bus/daemon) members THIS APP calls as a client
/// — verbatim member names from `bus/ibusimpl.c`'s `introspection_xml`
/// (curl'd 2026-09-14, not assumed). `getGlobalEngine`/
/// `currentInputContext` both carry `<annotation
/// name='org.freedesktop.DBus.Deprecated' value='true'/>` in that same
/// XML — kept anyway because the architect's own POC (T-IBUS-TIER2)
/// measured `get_global_engine()` as the reliable way to verify a switch
/// actually landed: "after the owning process disconnects,
/// `get_global_engine()` can report `None` while typing still works, so
/// the real build must force-reassert and verify `xkb:us::eng` rather
/// than trust the callback."
enum IBusBusMember {
  static let registerComponent = "RegisterComponent"
  static let setGlobalEngine = "SetGlobalEngine"
  static let getGlobalEngine = "GetGlobalEngine"
  static let currentInputContext = "CurrentInputContext"
}

/// `org.freedesktop.IBus.Factory`'s one member — INBOUND: the daemon
/// calls this ON US (see `IBusPath.factory`'s doc comment); this app
/// never calls it outward. Verbatim from `src/ibusfactory.c`'s
/// `introspection_xml`: `<method name='CreateEngine'><arg direction='in'
/// type='s' name='name' /><arg direction='out' type='o' /></method>`.
enum IBusFactoryMember {
  static let createEngine = "CreateEngine"
}

/// `org.freedesktop.IBus.Engine`'s INBOUND members this app dispatches —
/// verbatim member NAMES from `src/ibusengine.c`'s `introspection_xml`
/// (curl'd 2026-09-14). That same XML declares many MORE members this
/// app deliberately does not enumerate here (`SetCursorLocation`,
/// `ProcessHandWritingEvent`, `CancelHandWriting`, `PropertyShow`,
/// `PropertyHide`, `CandidateClicked`, `FocusInId`, `FocusOutId`,
/// `PageUp`, `PageDown`, `CursorUp`, `CursorDown`,
/// `PanelExtensionReceived`, `PanelExtensionRegisterKeys`) — see
/// `IBusInboundRequest.decode`'s doc comment for why every one of those
/// safely decodes to `.unknown` rather than crashing or being silently
/// swallowed.
enum IBusEngineMember {
  static let focusIn = "FocusIn"
  static let focusOut = "FocusOut"
  static let enable = "Enable"
  static let disable = "Disable"
  static let reset = "Reset"
  static let setCapabilities = "SetCapabilities"
  static let processKeyEvent = "ProcessKeyEvent"
  static let setSurroundingText = "SetSurroundingText"
  static let propertyActivate = "PropertyActivate"
}

/// OUTBOUND signals this app's Engine object emits (`IBusRequests` builds
/// them; nothing decodes them, since this app never receives its own
/// signals back).
///
/// **`deleteSurroundingText`/`requireSurroundingText` are deliberately
/// ABSENT from `src/ibusengine.c`'s own static `introspection_xml`** —
/// confirmed by curl'ing the real source and grepping for `<signal
/// name=` between `CommitText` and the closing `</interface>`: only
/// `CommitText`, `UpdatePreeditText`, `UpdateAuxiliaryText`,
/// `UpdateLookupTable`, `RegisterProperties`, `UpdateProperty`,
/// `ForwardKeyEvent`, `PanelExtension`, `SendMessage` are listed. This is
/// NOT an oversight in this module's reading of it: D-Bus signal emission
/// (`g_dbus_connection_emit_signal`, which `ibus_engine_emit_signal`
/// wraps — `src/ibusengine.c`) never requires the emitter's OWN
/// introspection data to declare a signal before sending it —
/// introspection only affects discoverability via
/// `org.freedesktop.DBus.Introspectable`, never delivery. A subscriber
/// that added an `AddMatch` rule scoped to this app's Engine object path
/// + interface (the live-connection layer this task doesn't build, same
/// shape as `ShellHelperRequests.addSignalsMatch`) receives both signals
/// regardless of their absence from the XML — confirmed directly against
/// `ibus_engine_delete_surrounding_text`/`ibus_engine_get_surrounding_text`
/// (`src/ibusengine.c`), which call the exact same
/// `ibus_engine_emit_signal(engine, "<name>", ...)` helper as every
/// XML-declared signal above.
enum IBusEngineSignal {
  static let commitText = "CommitText"
  static let deleteSurroundingText = "DeleteSurroundingText"
  static let requireSurroundingText = "RequireSurroundingText"
}

enum IBusErrorName {
  static let unknownMethod = "org.freedesktop.DBus.Error.UnknownMethod"
  static let invalidArgs = "org.freedesktop.DBus.Error.InvalidArgs"
}

/// `SetCapabilities`' `caps: u` bitmask — verbatim bit values from
/// `IBusCapabilite` (`src/ibustypes.h`, curl'd 2026-09-14):
/// `IBUS_CAP_PREEDIT_TEXT=1<<0, IBUS_CAP_AUXILIARY_TEXT=1<<1,
/// IBUS_CAP_LOOKUP_TABLE=1<<2, IBUS_CAP_FOCUS=1<<3, IBUS_CAP_PROPERTY=1<<4,
/// IBUS_CAP_SURROUNDING_TEXT=1<<5, IBUS_CAP_OSK=1<<6,
/// IBUS_CAP_SYNC_PROCESS_KEY=1<<7`. An `OptionSet` rather than named
/// cases for only the bits this module reads today, since a raw `UInt32`
/// this type wraps never loses information for bits it doesn't name.
public struct IBusCapabilities: OptionSet, Equatable, Sendable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let preeditText = IBusCapabilities(rawValue: 1 << 0)
  public static let auxiliaryText = IBusCapabilities(rawValue: 1 << 1)
  public static let lookupTable = IBusCapabilities(rawValue: 1 << 2)
  public static let focus = IBusCapabilities(rawValue: 1 << 3)
  public static let property = IBusCapabilities(rawValue: 1 << 4)

  /// **THE bit this whole task's headline finding turns on.**
  /// `SetCapabilities` carrying this bit is the client (GTK/Qt/VTE's IM
  /// context) advertising that its currently-focused control CAN answer a
  /// `RequireSurroundingText` request.
  ///
  /// **Not an unconditional guarantee, confirmed against both sides of
  /// the real protocol (curl'd 2026-09-14):** GTK's own
  /// `client/gtk2/ibusimcontext.c` sets `ibusimcontext->caps =
  /// IBUS_CAP_PREEDIT_TEXT | IBUS_CAP_FOCUS | IBUS_CAP_SURROUNDING_TEXT`
  /// for EVERY context up front, optimistically — it does not first check
  /// whether the about-to-be-focused widget actually supports it. It only
  /// finds out reactively: `_request_surrounding_text()` emits the
  /// widget's own `retrieve-surrounding` GTK signal, and if that signal
  /// comes back unhandled (`FALSE` — a widget with no text-buffer/IM
  /// integration), `_ibus_warn_no_support_surrounding_text()` LOGS a
  /// warning and CLEARS this bit for that context (`context->caps &=
  /// ~IBUS_CAP_SURROUNDING_TEXT`) from then on. So: this bit being set on
  /// `SetCapabilities` means "the toolkit believes surrounding-text is
  /// possible," not "the specific focused control has already proven it
  /// is" — the proof only arrives (or doesn't) on the first actual
  /// `RequireSurroundingText` round trip. GTK4's `GtkEntry`/`GtkTextView`
  /// and VTE terminals (VTE wires `retrieve-surrounding` in
  /// `src/widget.cc`, confirmed separately by this task's own architect)
  /// all genuinely implement it; a bespoke custom-drawn widget with no IM
  /// integration would not.
  public static let surroundingText = IBusCapabilities(rawValue: 1 << 5)
  public static let osk = IBusCapabilities(rawValue: 1 << 6)
  public static let syncProcessKey = IBusCapabilities(rawValue: 1 << 7)
}

/// The GObject type-name STRING each ibus "serializable" object's wire
/// tuple begins with — verbatim from each type's own
/// `G_DEFINE_TYPE`/`G_DEFINE_TYPE_WITH_PRIVATE` macro invocation (GLib's
/// own convention: `G_DEFINE_TYPE(IBusText, ibus_text, ...)` registers the
/// GType under the literal STRINGIFIED first argument, `"IBusText"` — not
/// a separately-chosen name). See `IBusRequests.serializedText(_:)`'s doc
/// comment for how this fits into the full wire tuple.
enum IBusSerializableTypeName {
  /// `src/ibustext.c`: `G_DEFINE_TYPE (IBusText, ibus_text, ...)`.
  static let text = "IBusText"
  /// `src/ibusattrlist.c`: `G_DEFINE_TYPE (IBusAttrList, ibus_attr_list, ...)`.
  static let attributeList = "IBusAttrList"
  /// `src/ibuscomponent.c`: `G_DEFINE_TYPE_WITH_PRIVATE (IBusComponent, ...)`.
  static let component = "IBusComponent"
  /// `src/ibusenginedesc.c`: `G_DEFINE_TYPE_WITH_PRIVATE (IBusEngineDesc, ...)`.
  static let engineDescription = "IBusEngineDesc"
}

/// A committed/surrounding `IBusText`, reduced to the ONE thing every
/// caller in this codebase needs: the plain text content. A real
/// `IBusText` also carries an `IBusAttrList` of presentation attributes
/// (underline ranges, colors, ...) — this app never sets or reads them
/// (it only ever COMMITS plain, unstyled text, and only ever READS
/// surrounding text to look for a keyword, never its styling); see
/// `IBusRequests.serializedText(_:)`/`IBusResponses.parseIBusText(_:)`
/// for how a genuinely valid, empty `IBusAttrList` is still built/
/// accepted on the wire rather than the field being omitted.
public struct IBusText: Equatable, Sendable {
  public var text: String

  public init(text: String) { self.text = text }
}
