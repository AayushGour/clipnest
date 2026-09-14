import Foundation

/// Pure parsers for every reply this app ever reads back from
/// `org.freedesktop.IBus` (the calls `IBusRequests` builds), plus the one
/// shared decoder (`parseIBusText`) `IBusEngineDispatcher` reuses to
/// decode an INBOUND `SetSurroundingText`'s `text` argument — mirrors
/// `ShellHelperResponses`' identical role.
/// `public` (T-IBUS-CLIENT): `IBusCommitClient` (`ClipnestLinuxAppKit`)
/// directly calls `isSuccessReply`/`parseGetGlobalEngineReply` — see
/// `IBusRequests`'s identical widening note. `parseCurrentInputContextReply`/
/// `parseIBusText` stay internal; nothing outside this module needs them.
public enum IBusResponses {
  /// `RegisterComponent`/`SetGlobalEngine` have no reply payload at all
  /// (see `bus/ibusimpl.c`'s `introspection_xml` — neither declares an
  /// `out` arg) — success is simply "the daemon answered with
  /// METHOD_RETURN, not ERROR."
  public static func isSuccessReply(_ message: DBusMessage) -> Bool {
    message.type == .methodReturn
  }

  /// `GetGlobalEngine() -> (v)` wrapping a full serialized `IBusEngineDesc`
  /// — deprecated in ibus's own XML but still what the architect's POC
  /// measured as the reliable post-switch check (T-IBUS-TIER2: "the real
  /// build must force-reassert and verify `xkb:us::eng` rather than trust
  /// the callback"). Only the `name` field is decoded — field index 2 in
  /// the serialized tuple (`IBusEngineDescriptor.serialized()`'s own
  /// field-order doc comment: index 0 is the type name, index 1 the
  /// attachments dict, index 2 the engine's own `name`) — this app has no
  /// use for any of the other 16 fields today.
  public static func parseGetGlobalEngineReply(_ message: DBusMessage) -> String? {
    guard message.type == .methodReturn,
      case .variant(.structure(let fields))? = message.body.first,
      fields.count > 2, case .string(let name) = fields[2]
    else { return nil }
    return name
  }

  /// `CurrentInputContext() -> (o)`.
  static func parseCurrentInputContextReply(_ message: DBusMessage) -> String? {
    guard message.type == .methodReturn, case .objectPath(let path)? = message.body.first else {
      return nil
    }
    return path
  }

  /// Reverses `IBusRequests.serializedText(_:)`'s exact `(s a{sv} s v)`
  /// tuple shape — see that function's doc comment for the full citation
  /// trail. Only `fields[2]` (the actual text content) is ever surfaced;
  /// `fields[0]` (the type-name string) IS validated as `"IBusText"`
  /// rather than skipped, so a differently-shaped `v` argument (e.g. a
  /// malformed message, or some other serializable entirely) is REJECTED
  /// rather than silently misread as text — exactly the class of bug
  /// T-ATSPI1/D95 (an assumed wire shape encoded identically in
  /// production code and its own test) is meant to guard against here:
  /// this check only has teeth because the shape being checked came from
  /// upstream source, not from `serializedText(_:)`'s own author guessing
  /// twice.
  static func parseIBusText(_ value: DBusValue) -> IBusText? {
    guard case .variant(.structure(let fields)) = value, fields.count >= 3,
      case .string(IBusSerializableTypeName.text) = fields[0],
      case .string(let text) = fields[2]
    else { return nil }
    return IBusText(text: text)
  }
}
