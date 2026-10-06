import Foundation

/// Pure builders for every message THIS APP ever sends: `org.freedesktop
/// .IBus` method calls made AS A CLIENT, plus the signals an ENGINE
/// instance emits back to the daemon — mirrors `ShellHelperRequests`'
/// identical split (message construction kept separate from whatever
/// connection eventually sends it; see that enum's doc comment). No live
/// `DBusConnection`/socket code exists in this module for IBus yet — see
/// `IBusEngineDispatcher.swift`'s doc comment for what's deliberately not
/// built by this task.
/// `public` (T-IBUS-CLIENT): `IBusCommitClient` (`ClipnestLinuxAppKit`) is a
/// cross-module caller of the specific builders below it directly drives
/// (`registerComponent`/`setGlobalEngine`/`getGlobalEngine`/`commitText`/
/// `deleteSurroundingText`) — matching this file's own top-level doc
/// comment anticipating that "a future task may need to widen a few of
/// these to public, a trivial, safe visibility-only change." **Also
/// `public` (T-IBUS-REPLACER): `requireSurroundingText` — the corrected
/// gate (`IBusCommitOutcome`'s own doc comment) has `IBusCommitClient` emit
/// it directly.** `currentInputContext`/`serializedText` stay internal:
/// nothing outside this module needs them yet.
public enum IBusRequests {
  // MARK: - org.freedesktop.IBus (bus/daemon) calls this app makes as a client

  /// `RegisterComponent(component: v)` — verbatim from `bus/ibusimpl.c`'s
  /// `introspection_xml` (curl'd 2026-09-14): `<method
  /// name='RegisterComponent'><arg direction='in' type='v'
  /// name='component' /></method>`. No reply payload — success is "the
  /// daemon returned METHOD_RETURN at all" (`IBusResponses.isSuccessReply`).
  public static func registerComponent(_ component: IBusComponentDescriptor, serial: UInt32)
    -> DBusMessage
  {
    DBusMessage(
      type: .methodCall, serial: serial, path: IBusPath.bus, interface: IBusInterface.bus,
      member: IBusBusMember.registerComponent, destination: IBusBusName.daemon,
      body: [.variant(component.serialized())])
  }

  /// `SetGlobalEngine(engine_name: s)` — no reply payload.
  public static func setGlobalEngine(name: String, serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: IBusPath.bus, interface: IBusInterface.bus,
      member: IBusBusMember.setGlobalEngine, destination: IBusBusName.daemon,
      body: [.string(name)])
  }

  /// `GetGlobalEngine() -> (v)`. Deprecated in ibus's own XML but still
  /// the mechanism the architect's POC (T-IBUS-TIER2) measured as the
  /// reliable post-switch verification — see `IBusBusMember`'s doc
  /// comment.
  public static func getGlobalEngine(serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: IBusPath.bus, interface: IBusInterface.bus,
      member: IBusBusMember.getGlobalEngine, destination: IBusBusName.daemon)
  }

  /// `CurrentInputContext() -> (o)`. Also deprecated in ibus's own XML;
  /// kept for the same reason as `getGlobalEngine` above.
  static func currentInputContext(serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: IBusPath.bus, interface: IBusInterface.bus,
      member: IBusBusMember.currentInputContext, destination: IBusBusName.daemon)
  }

  // MARK: - org.freedesktop.IBus.Engine signals THIS APP emits as an engine

  /// `CommitText(text: v)` — `objectPath` is THIS engine instance's own
  /// object path (`IBusPath.engine(id:)`). `destination` is deliberately
  /// left `nil` (unlike every method-call builder above): D-Bus signals
  /// are broadcast-by-default and the daemon routes them by path +
  /// interface, the same shape `ShellHelperRequests.addSignalsMatch`'s
  /// own doc comment describes for the RECEIVING side of this pattern.
  public static func commitText(_ text: IBusText, objectPath: String, serial: UInt32) -> DBusMessage
  {
    DBusMessage(
      type: .signal, serial: serial, path: objectPath, interface: IBusInterface.engine,
      member: IBusEngineSignal.commitText, body: [.variant(serializedText(text))])
  }

  /// `DeleteSurroundingText(offset_from_cursor: i, nchars: u)`. Both
  /// arguments are UNICODE CHARACTER (UCS-4 codepoint) counts, NOT UTF-8
  /// bytes, UTF-16 units, or grapheme clusters — confirmed by the REAL
  /// deletion arithmetic in `ibus_engine_delete_surrounding_text`
  /// (`src/ibusengine.c`, curl'd 2026-09-14), not inferred from a
  /// same-author helper (the exact failure mode T-ATSPI1/D95 already cost
  /// this codebase once): it converts the cached surrounding text to
  /// UCS-4 (`g_utf8_to_ucs4_fast`) and computes `cursor_pos =
  /// priv->surrounding_cursor_pos + offset_from_cursor`, then `memmove`s
  /// over that `gunichar` (one element per Unicode scalar value) array
  /// using `cursor_pos`/`nchars` directly as array indices/counts — never
  /// touching the original UTF-8 byte buffer for the actual cut. The
  /// exact wire call this mirrors: `g_variant_new("(iu)",
  /// offset_from_cursor, nchars)` inside that same function.
  public static func deleteSurroundingText(
    offsetFromCursor: Int32, characterCount: UInt32, objectPath: String, serial: UInt32
  ) -> DBusMessage {
    DBusMessage(
      type: .signal, serial: serial, path: objectPath, interface: IBusInterface.engine,
      member: IBusEngineSignal.deleteSurroundingText,
      body: [.int32(offsetFromCursor), .uint32(characterCount)])
  }

  /// `RequireSurroundingText()` — NULLARY (empty body), per
  /// `ibus_engine_get_surrounding_text`'s own `ibus_engine_emit_signal
  /// (engine, "RequireSurroundingText", NULL)` (`src/ibusengine.c`,
  /// curl'd 2026-09-14). See `IBusCapabilities.surroundingText`'s doc
  /// comment for whether this reliably produces a `SetSurroundingText` in
  /// return.
  /// `public` (T-IBUS-REPLACER): `IBusCommitClient` (`ClipnestLinuxAppKit`)
  /// emits this directly, once `FocusIn` confirms our engine is bound to
  /// SOME input context, to trigger the client's `SetSurroundingText`
  /// answer — the corrected gate (see `IBusCommitOutcome`'s own doc
  /// comment for why `FocusIn` alone was found insufficient). This is
  /// exactly the widening `IBusRequests`' own top doc comment anticipated
  /// ("a future task may need to widen a few of these to public").
  public static func requireSurroundingText(objectPath: String, serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .signal, serial: serial, path: objectPath, interface: IBusInterface.engine,
      member: IBusEngineSignal.requireSurroundingText)
  }

  // MARK: - IBusText wire serialization (shared with IBusResponses.parseIBusText)

  /// The full `(s a{sv} s v)` wire tuple a real `IBusText` serializes to —
  /// verbatim from THREE separate upstream functions, chained EXACTLY as
  /// ibus's own code chains them (curl'd 2026-09-14, not assumed):
  ///
  /// 1. `ibus_serializable_serialize_object` (`src/ibusserializable.c`):
  ///    opens a `G_VARIANT_TYPE_TUPLE` builder and adds the GObject type
  ///    NAME string first — `g_variant_builder_add(&builder, "s",
  ///    g_type_name(G_OBJECT_TYPE(object)))` — `"IBusText"`, verbatim
  ///    from `G_DEFINE_TYPE(IBusText, ibus_text, ...)`'s own stringified
  ///    first argument (`src/ibustext.c`). -> index 0.
  /// 2. `ibus_serializable_real_serialize`, the BASE class's serialize,
  ///    which every subclass calls first via `IBUS_SERIALIZABLE_CLASS
  ///    (parent_class)->serialize(...)`: adds the attachments dict,
  ///    `g_variant_builder_add(builder, "a{sv}", &array)` — empty here,
  ///    this app never attaches anything. -> index 1.
  /// 3. `ibus_text_serialize` (`src/ibustext.c`) itself, called AFTER the
  ///    base above: `g_variant_builder_add(builder, "s", text->text)` ->
  ///    index 2, then `g_variant_builder_add(builder, "v",
  ///    ibus_serializable_serialize((IBusSerializable*)text->attrs))` ->
  ///    index 3 — the attrs variant is itself a serialized `IBusAttrList`,
  ///    whose OWN tuple is `(s a{sv} av)` (`ibus_attr_list_serialize`,
  ///    `src/ibusattrlist.c`: base `(s a{sv})` + one `av` field, an empty
  ///    array of variant-wrapped `IBusAttribute`s here since this app
  ///    never sets presentation attributes).
  static func serializedText(_ text: IBusText) -> DBusValue {
    let emptyAttributeList = DBusValue.structure([
      .string(IBusSerializableTypeName.attributeList),
      .emptyArray(elementSignature: "{sv}"),
      .emptyArray(elementSignature: "v"),
    ])
    return .structure([
      .string(IBusSerializableTypeName.text),
      .emptyArray(elementSignature: "{sv}"),
      .string(text.text),
      .variant(emptyAttributeList),
    ])
  }
}

/// The real subset of `IBusEngineDesc`'s fields `RegisterComponent`'s
/// component descriptor needs to carry per engine. Field ORDER below is
/// load-bearing (see `serialized()`'s own doc comment) and matches
/// `ibus_engine_desc_serialize` (`src/ibusenginedesc.c`, curl'd
/// 2026-09-14) exactly; fields that struct has but this app never varies
/// are still emitted, always `""`, so the tuple's ARITY matches upstream
/// even though this app has no use for them today.
public struct IBusEngineDescriptor: Equatable, Sendable {
  public var name: String
  public var longName: String
  public var description: String
  public var language: String
  public var license: String
  public var author: String
  public var icon: String
  public var layout: String
  public var rank: UInt32

  public init(
    name: String, longName: String, description: String, language: String, license: String = "",
    author: String = "", icon: String = "", layout: String = "us", rank: UInt32 = 0
  ) {
    self.name = name
    self.longName = longName
    self.description = description
    self.language = language
    self.license = license
    self.author = author
    self.icon = icon
    self.layout = layout
    self.rank = rank
  }

  /// `(s a{sv} s s s s s s s s u s s s s s s s s)` — verbatim field order
  /// from `ibus_engine_desc_serialize` (`src/ibusenginedesc.c`, curl'd
  /// 2026-09-14): base type-name + empty attachments (2), then
  /// name/longname/description/language/license/author/icon/layout (8
  /// strings), rank (`u`), then hotkeys/symbol/setup/layout_variant/
  /// layout_option/version/textdomain/icon_prop_key (8 more strings this
  /// app always leaves empty). Upstream's own serializer wraps every one
  /// of those trailing fields in a `NOTNULL()` macro that coerces a NULL
  /// C string to `""` — so an empty string here is the SAME wire value a
  /// real ibus engine sends when it never set them, not a shortcut this
  /// module invented.
  func serialized() -> DBusValue {
    .structure([
      .string(IBusSerializableTypeName.engineDescription),
      .emptyArray(elementSignature: "{sv}"),
      .string(name), .string(longName), .string(description), .string(language),
      .string(license), .string(author), .string(icon), .string(layout),
      .uint32(rank),
      .string(""), .string(""), .string(""), .string(""), .string(""), .string(""), .string(""),
      .string(""),
    ])
  }
}

/// The real subset of `IBusComponent`'s fields `RegisterComponent` needs
/// — field order verbatim from `ibus_component_serialize`
/// (`src/ibuscomponent.c`, curl'd 2026-09-14).
public struct IBusComponentDescriptor: Equatable, Sendable {
  public var name: String
  public var description: String
  public var version: String
  public var license: String
  public var author: String
  public var homepage: String
  public var exec: String
  public var textDomain: String
  public var engines: [IBusEngineDescriptor]

  /// Explicit (public structs don't synthesize a public memberwise init) —
  /// field order here is just constructor-argument order, NOT the wire
  /// order `serialized()` below emits; that order is cited separately, in
  /// `serialized()`'s own doc comment.
  public init(
    name: String, description: String, version: String, license: String, author: String,
    homepage: String, exec: String, textDomain: String, engines: [IBusEngineDescriptor]
  ) {
    self.name = name
    self.description = description
    self.version = version
    self.license = license
    self.author = author
    self.homepage = homepage
    self.exec = exec
    self.textDomain = textDomain
    self.engines = engines
  }

  /// `(s a{sv} s s s s s s s s av av)` — base type-name + empty
  /// attachments (2), then name/description/version/license/author/
  /// homepage/exec/textdomain (8 strings), `observed_paths` (`av`, always
  /// empty here — this app never populates it, same as a
  /// programmatically-registered component with no on-disk `.xml` file),
  /// then `engines` (`av`, one variant-wrapped `IBusEngineDesc` per
  /// entry) — verbatim field order from `ibus_component_serialize`
  /// (`src/ibuscomponent.c`, curl'd 2026-09-14).
  func serialized() -> DBusValue {
    let engineVariants = engines.map { DBusValue.variant($0.serialized()) }
    return .structure([
      .string(IBusSerializableTypeName.component),
      .emptyArray(elementSignature: "{sv}"),
      .string(name), .string(description), .string(version), .string(license),
      .string(author), .string(homepage), .string(exec), .string(textDomain),
      .emptyArray(elementSignature: "v"),
      DBusValue.array(engineVariants, elementSignature: "v"),
    ])
  }
}
