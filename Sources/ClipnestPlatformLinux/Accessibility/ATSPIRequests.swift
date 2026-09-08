import Foundation

/// Pure builders for every AT-SPI/D-Bus method-call message this module
/// ever sends — separated from `ATSPITextAccessor`'s control flow so the
/// exact wire shape (destination, path, interface, member, body — including
/// the byte-vs-character offset conversion in `insertText`) is directly
/// unit-testable.
enum ATSPIRequests {
  static func getAddress(serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ATSPIPath.bus, interface: ATSPIInterface.bus,
      member: ATSPIMember.getAddress, destination: ATSPIBusName.a11yBusService)
  }

  static func getIsEnabled(serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ATSPIPath.bus, interface: ATSPIInterface.properties,
      member: ATSPIMember.propertiesGet, destination: ATSPIBusName.a11yBusService,
      body: [.string(ATSPIInterface.status), .string(ATSPIProperty.isEnabled)])
  }

  static func registerFocusEvent(serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ATSPIPath.registry,
      interface: ATSPIInterface.registry, member: ATSPIMember.registerEvent,
      destination: ATSPIBusName.registry, body: [.string(ATSPIEventName.focused)])
  }

  static func addFocusMatch(serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ATSPIPath.dbusDaemon, interface: ATSPIInterface.dbus,
      member: ATSPIMember.addMatch, destination: ATSPIBusName.dbusDaemon,
      body: [.string(ATSPIMatchRule.stateChanged)])
  }

  static func getNSelections(busName: String, objectPath: String, serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: objectPath, interface: ATSPIInterface.text,
      member: ATSPIMember.getNSelections, destination: busName)
  }

  static func getSelection(
    busName: String, objectPath: String, selectionIndex: Int32, serial: UInt32
  ) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: objectPath, interface: ATSPIInterface.text,
      member: ATSPIMember.getSelection, destination: busName, body: [.int32(selectionIndex)])
  }

  static func getText(
    busName: String, objectPath: String, start: Int32, end: Int32, serial: UInt32
  ) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: objectPath, interface: ATSPIInterface.text,
      member: ATSPIMember.getText, destination: busName, body: [.int32(start), .int32(end)])
  }

  static func deleteText(
    busName: String, objectPath: String, start: Int32, end: Int32, serial: UInt32
  ) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: objectPath, interface: ATSPIInterface.editableText,
      member: ATSPIMember.deleteText, destination: busName, body: [.int32(start), .int32(end)])
  }

  /// `InsertText(position, text, length)` — `position` is a
  /// character/scalar OFFSET, but `length` is a UTF-8 BYTE count of `text`
  /// (see `UTF8OffsetConversion`'s doc comment for the off-by-N this
  /// distinguishes).
  static func insertText(
    busName: String, objectPath: String, position: Int32, text: String, serial: UInt32
  ) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: objectPath, interface: ATSPIInterface.editableText,
      member: ATSPIMember.insertText, destination: busName,
      body: [
        .int32(position), .string(text), .int32(UTF8OffsetConversion.utf8ByteCount(of: text)),
      ])
  }
}

/// Pure parsers for every AT-SPI/D-Bus reply this module ever reads.
enum ATSPIResponses {
  static func parseInt32Reply(_ message: DBusMessage) -> Int32? {
    guard message.type == .methodReturn, case .int32(let value)? = message.body.first else {
      return nil
    }
    return value
  }

  /// `Text.GetSelection(selectionNum: i) -> (startOffset: i, endOffset: i)` —
  /// TWO separate top-level `out` arguments, per the interface's own
  /// introspection XML (`at-spi2-core`'s `xml/Text.xml`, confirmed against
  /// the real GNOME source), NOT one `(ii)` STRUCT. This distinction is
  /// real on the wire, not just cosmetic: a D-Bus reply body is the ordered
  /// list of its `out` arguments' values; a struct is a single value that
  /// happens to CONTAIN two ints, an entirely different marshalled shape
  /// (`ii` vs `(ii)`). A prior version of this parser assumed the struct
  /// shape and was never caught, because its own unit test encoded the same
  /// wrong assumption as a canned reply — this is exactly why this whole
  /// D-Bus layer is "manual-verify only" and gets exercised against a REAL
  /// accessibility bus rather than trusted from reasoning alone: captured
  /// directly off a real `dbus-monitor` tap against a live GTK4
  /// `Text.GetSelection` call, the actual reply body is `int32 7` followed
  /// by a SEPARATE top-level `int32 13` — never a nested structure — which
  /// made the old parser return `nil` on every real call, silently
  /// collapsing `SnippetExpander`'s whole Accessibility-first tier to the
  /// clipboard fallback for every single app, always.
  static func parseSelectionReply(_ message: DBusMessage) -> (start: Int32, end: Int32)? {
    guard message.type == .methodReturn, message.body.count >= 2,
      case .int32(let start) = message.body[0], case .int32(let end) = message.body[1]
    else { return nil }
    return (start, end)
  }

  static func parseStringReply(_ message: DBusMessage) -> String? {
    guard message.type == .methodReturn, case .string(let value)? = message.body.first else {
      return nil
    }
    return value
  }

  static func parseBooleanReply(_ message: DBusMessage) -> Bool? {
    guard message.type == .methodReturn, case .boolean(let value)? = message.body.first else {
      return nil
    }
    return value
  }

  /// `org.freedesktop.DBus.Properties.Get` always wraps its result in a
  /// `VARIANT`.
  static func parseBooleanPropertyReply(_ message: DBusMessage) -> Bool? {
    guard message.type == .methodReturn, case .variant(let inner)? = message.body.first,
      case .boolean(let value) = inner
    else { return nil }
    return value
  }
}
