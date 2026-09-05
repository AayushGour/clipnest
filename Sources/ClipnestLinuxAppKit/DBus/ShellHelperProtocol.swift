import ClipnestPlatformLinux
import Foundation

/// Pure builders for every `app.clipnest.ShellHelper1` method call this
/// app ever sends — mirrors `ClipnestPlatformLinux.ATSPIRequests`'s split
/// (message construction separate from the connection that sends it).
///
/// Every UNIX-fd-carrying member the contract XML defines
/// (`SetClipboardWatch`/`GetClipboardMimeTypes`/`ReadClipboard`/
/// `SetClipboard`/`ClipboardChanged`) is DELIBERATELY absent here — see
/// this task's decision log: `DBusValue` has no `UNIX_FD` case and
/// `DBusConnection` sends/receives over a plain `read`/`write` byte
/// stream, not `sendmsg`/`recvmsg` with `SCM_RIGHTS` ancillary data. Both
/// live in `ClipnestPlatformLinux`, out of this task's file-ownership
/// scope, and the task brief is explicit that this module must reuse the
/// existing D-Bus implementation rather than write a second one — so
/// those five members are flagged as a follow-up for whoever owns that
/// module, not worked around here.
enum ShellHelperRequests {
  static func getCapabilities(serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ShellHelperName.objectPath,
      interface: FreedesktopPropertiesName.interface, member: FreedesktopPropertiesMember.get,
      destination: ShellHelperName.busName,
      body: [.string(ShellHelperName.interface), .string(ShellHelperProperty.capabilities)])
  }

  static func getFocusedApp(serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ShellHelperName.objectPath,
      interface: ShellHelperName.interface, member: ShellHelperMember.getFocusedApp,
      destination: ShellHelperName.busName)
  }

  static func getPointer(serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ShellHelperName.objectPath,
      interface: ShellHelperName.interface, member: ShellHelperMember.getPointer,
      destination: ShellHelperName.busName)
  }

  static func getMonitorWorkArea(monitor: Int32, serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ShellHelperName.objectPath,
      interface: ShellHelperName.interface, member: ShellHelperMember.getMonitorWorkArea,
      destination: ShellHelperName.busName, body: [.int32(monitor)])
  }

  static func sendKeyChord(keyval: UInt32, modifiers: UInt32, serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ShellHelperName.objectPath,
      interface: ShellHelperName.interface, member: ShellHelperMember.sendKeyChord,
      destination: ShellHelperName.busName, body: [.uint32(keyval), .uint32(modifiers)])
  }

  static func focusAndSendKeyChord(
    windowSerial: UInt64, keyval: UInt32, modifiers: UInt32, serial: UInt32
  ) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ShellHelperName.objectPath,
      interface: ShellHelperName.interface, member: ShellHelperMember.focusAndSendKeyChord,
      destination: ShellHelperName.busName,
      body: [.uint64(windowSerial), .uint32(keyval), .uint32(modifiers)])
  }

  static func placeWindow(
    windowToken: String, x: Int32, y: Int32, flags: UInt32, serial: UInt32
  ) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ShellHelperName.objectPath,
      interface: ShellHelperName.interface, member: ShellHelperMember.placeWindow,
      destination: ShellHelperName.busName,
      body: [.string(windowToken), .int32(x), .int32(y), .uint32(flags)])
  }

  static func unplaceWindow(windowToken: String, serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: ShellHelperName.objectPath,
      interface: ShellHelperName.interface, member: ShellHelperMember.unplaceWindow,
      destination: ShellHelperName.busName, body: [.string(windowToken)])
  }
}

/// Pure parsers for every `app.clipnest.ShellHelper1` reply/signal this
/// app ever reads.
enum ShellHelperResponses {
  /// `org.freedesktop.DBus.Properties.Get` always wraps its result in a
  /// `VARIANT` — mirrors `ClipnestPlatformLinux.ATSPIResponses
  /// .parseBooleanPropertyReply`'s identical unwrap, generalized to the
  /// `as` (string array) shape `Capabilities` actually has.
  static func parseCapabilities(_ message: DBusMessage) -> [String]? {
    guard message.type == .methodReturn, case .variant(let inner)? = message.body.first,
      case .array(let items) = inner
    else { return nil }
    return items.compactMap {
      if case .string(let value) = $0 { return value }
      return nil
    }
  }

  static func parseBooleanReply(_ message: DBusMessage) -> Bool? {
    guard message.type == .methodReturn, case .boolean(let value)? = message.body.first else {
      return nil
    }
    return value
  }

  /// `FocusAndSendKeyChord`'s `result` is a plain string enum
  /// (`"ok" | "target-lost" | "modifiers-held" | "unsupported"`), per the
  /// contract XML's own inline comment.
  static func parseFocusAndSendKeyChordResult(_ message: DBusMessage) -> String? {
    guard message.type == .methodReturn, case .string(let value)? = message.body.first else {
      return nil
    }
    return value
  }

  static func parseGetPointer(_ message: DBusMessage) -> (x: Int32, y: Int32, monitor: Int32)? {
    guard message.type == .methodReturn, message.body.count == 3,
      case .int32(let x) = message.body[0], case .int32(let y) = message.body[1],
      case .int32(let monitor) = message.body[2]
    else { return nil }
    return (x, y, monitor)
  }

  static func parseGetMonitorWorkArea(
    _ message: DBusMessage
  ) -> (x: Int32, y: Int32, width: Int32, height: Int32)? {
    guard message.type == .methodReturn, case .structure(let fields)? = message.body.first,
      fields.count == 4, case .int32(let x) = fields[0], case .int32(let y) = fields[1],
      case .int32(let width) = fields[2], case .int32(let height) = fields[3]
    else { return nil }
    return (x, y, width, height)
  }

  /// `ShortcutActivated(action, timestamp, pointer_x, pointer_y, monitor,
  /// focus)` — the signal `Keybindings`/the placement module fire when a
  /// mutter-level shortcut fires INSIDE the compositor, carrying the
  /// pointer/monitor/focus info only the compositor can know at that exact
  /// instant (see this task's directive). `focus`'s `a{sv}` keys are
  /// surfaced the same shallow way `ShowPickerOptions.parse` treats
  /// `ShowPicker`'s own `focus` sub-dict — decoding its VALUES is
  /// `GetFocusedApp`'s concern, called separately if a caller needs them.
  static func parseShortcutActivated(
    _ message: DBusMessage
  ) -> (action: String, timestamp: UInt32, pointerX: Int32, pointerY: Int32, monitor: Int32)? {
    guard message.type == .signal, message.member == ShellHelperMember.shortcutActivated,
      message.body.count >= 5, case .string(let action) = message.body[0],
      case .uint32(let timestamp) = message.body[1], case .int32(let x) = message.body[2],
      case .int32(let y) = message.body[3], case .int32(let monitor) = message.body[4]
    else { return nil }
    return (action, timestamp, x, y, monitor)
  }

  /// Translates a decoded `ShortcutActivated` signal straight into the
  /// `ShowPickerOptions` this app's own `ShowPicker` handler understands —
  /// so the extension's compositor-sourced pointer/monitor info reaches
  /// the picker through the exact same options struct a D-Bus-originated
  /// `ShowPicker` call would use, with zero duplicated field mapping.
  static func showPickerOptions(
    forAction action: (
      action: String, timestamp: UInt32, pointerX: Int32, pointerY: Int32, monitor: Int32
    )
  ) -> ShowPickerOptions {
    ShowPickerOptions(
      pointer: (action.pointerX, action.pointerY), monitor: action.monitor, focusKeys: [])
  }
}
