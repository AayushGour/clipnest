import ClipnestPlatformLinux
import Foundation

/// D-Bus error names this service ever replies with — kept alongside the
/// rest of this module's magic-string constants rather than inline at the
/// one call site that uses each.
enum ClipnestControlErrorName {
  static let unknownMethod = "org.freedesktop.DBus.Error.UnknownMethod"
  static let invalidArgs = "org.freedesktop.DBus.Error.InvalidArgs"
}

/// Why `ClipnestControlService.receiveLoop()` silently `continue`d instead
/// of sending a reply — extracted as its own pure, directly-testable type
/// (T-LX2: the receive loop's three bare `continue`s used to make "a
/// malformed message," "an undecodable one," and "no message at all"
/// indistinguishable at runtime) with the same "pure logic, no D-Bus I/O"
/// split as `ClipnestControlRequest`/`ClipnestControlReplies` above, so the
/// exact wording has test coverage without a real `DBusConnection`.
///
/// Deliberately does NOT cover `connection.receiveOneMessage(timeout:)`
/// returning `nil` (the loop's first `continue`) — that fires every
/// second whenever nothing arrives at all, which is this loop's normal
/// idle state, not a rejection of anything; logging it would just be noise
/// on every poll, matching how `ATSPIFocusTracker.readLoop()`'s identical
/// idle `continue` is likewise silent. What IS worth logging is a message
/// that was actually received and then dropped, which is exactly the two
/// cases below.
///
/// Metadata only, per coding-standards.md's privacy rule: an interface and
/// member name, never a message body.
enum ClipnestControlReceiveRejection {
  /// `ClipnestControlRequest.decode` returned `nil`: something was read
  /// off the wire, but it wasn't a method call at all (e.g. a stray signal
  /// or another connection's reply this connection happened to see).
  case notAMethodCall(DBusMessage)
  /// `ClipnestControlDispatcher.handle` returned `nil`: a real method call
  /// this service recognized produced no reply. Unreachable today — every
  /// `ClipnestControlDispatcher.handle` branch currently replies — kept so
  /// a future branch that legitimately shouldn't reply doesn't silently
  /// regress back into "indistinguishable from nothing happened at all."
  case noReplyProduced(DBusMessage)

  var logDescription: String {
    switch self {
    case .notAMethodCall(let message):
      return
        "ignored non-method-call message (type=\(message.type), interface=\(message.interface ?? "?"), member=\(message.member ?? "?"))"
    case .noReplyProduced(let message):
      return
        "dispatcher produced no reply (interface=\(message.interface ?? "?"), member=\(message.member ?? "?"))"
    }
  }
}

/// Every incoming request `ClipnestControlService` can receive on
/// `app.clipnest.Control` or `org.freedesktop.Application`, decoded from
/// the raw `DBusMessage` the bus hands the service. Pure — no D-Bus I/O —
/// so the dispatch decision itself (which member on which interface maps
/// to which app action, and how `ShowPicker`'s argument is unpacked) is
/// directly unit-testable without a real bus connection.
enum ClipnestControlRequest: Equatable {
  case togglePicker
  case showPicker(ShowPickerOptions)
  case hidePicker
  case expandSnippet
  case openSettings
  case ping
  case getCapabilities
  case getAllProperties
  /// `org.freedesktop.Application.Activate(a{sv})` — the platform default
  /// action when something D-Bus-activates this app with no specific verb
  /// (e.g. `gio launch`, a `.desktop` file's `DBusActivatable=true` path).
  /// Treated identically to `togglePicker`, mirroring what a plain
  /// double-click/launch of a menu-bar-style app does.
  case activate
  case open([String])
  case activateAction(name: String)
  /// Recognized member on a recognized interface, but with a body shape
  /// this service can't parse (e.g. `ActivateAction` missing its `name`
  /// argument) — maps to `InvalidArgs`, not `UnknownMethod`.
  case malformed
  /// An interface/member this service doesn't implement at all — maps to
  /// `UnknownMethod`.
  case unknown

  /// Decodes exactly one incoming method call. `nil` for anything that
  /// isn't a method call at all (a reply/signal this connection happened
  /// to read, which should simply be ignored rather than answered).
  static func decode(_ message: DBusMessage) -> ClipnestControlRequest? {
    guard message.type == .methodCall else { return nil }

    switch message.interface {
    case ClipnestControlName.controlInterface:
      return decodeControlMember(message)
    case FreedesktopApplicationName.interface:
      return decodeApplicationMember(message)
    case FreedesktopPropertiesName.interface:
      return decodePropertiesMember(message)
    default:
      return .unknown
    }
  }

  private static func decodeControlMember(_ message: DBusMessage) -> ClipnestControlRequest {
    switch message.member {
    case ClipnestControlMember.togglePicker: return .togglePicker
    case ClipnestControlMember.showPicker:
      guard let first = message.body.first else { return .showPicker(.empty) }
      return .showPicker(ShowPickerOptions.parse(first))
    case ClipnestControlMember.hidePicker: return .hidePicker
    case ClipnestControlMember.expandSnippet: return .expandSnippet
    case ClipnestControlMember.openSettings: return .openSettings
    case ClipnestControlMember.ping: return .ping
    default: return .unknown
    }
  }

  private static func decodeApplicationMember(_ message: DBusMessage) -> ClipnestControlRequest {
    switch message.member {
    case FreedesktopApplicationMember.activate: return .activate
    case FreedesktopApplicationMember.open:
      guard case .array(let items)? = message.body.first else { return .open([]) }
      return .open(
        items.compactMap {
          if case .string(let value) = $0 { return value }
          return nil
        })
    case FreedesktopApplicationMember.activateAction:
      guard case .string(let name)? = message.body.first else { return .malformed }
      return .activateAction(name: name)
    default: return .unknown
    }
  }

  private static func decodePropertiesMember(_ message: DBusMessage) -> ClipnestControlRequest {
    switch message.member {
    case FreedesktopPropertiesMember.get:
      guard message.body.count == 2, case .string(let interface) = message.body[0],
        case .string(let property) = message.body[1],
        interface == ClipnestControlName.controlInterface,
        property == ClipnestControlProperty.capabilities
      else { return .malformed }
      return .getCapabilities
    case FreedesktopPropertiesMember.getAll:
      guard case .string(let interface)? = message.body.first,
        interface == ClipnestControlName.controlInterface
      else { return .malformed }
      return .getAllProperties
    default: return .unknown
    }
  }
}

/// Pure builders for every reply `ClipnestControlService` ever sends —
/// separated from the connection/dispatch loop for the same testability
/// reason `ClipnestControlRequest.decode` is.
enum ClipnestControlReplies {
  static func empty(replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender)
  }

  static func capabilities(_ capabilities: [String], replyingTo message: DBusMessage)
    -> DBusMessage
  {
    DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender,
      body: [.variant(.array(capabilities.map(DBusValue.string)))])
  }

  static func allProperties(_ capabilities: [String], replyingTo message: DBusMessage)
    -> DBusMessage
  {
    let entry = DBusValue.dictEntry(
      .string(ClipnestControlProperty.capabilities),
      .variant(.array(capabilities.map(DBusValue.string))))
    return DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender,
      body: [.array([entry])])
  }

  static func unknownMethod(replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .error, serial: 0, errorName: ClipnestControlErrorName.unknownMethod,
      replySerial: message.serial, destination: message.sender,
      body: [.string("No such member '\(message.member ?? "?")' on '\(message.interface ?? "?")'")]
    )
  }

  static func invalidArgs(replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .error, serial: 0, errorName: ClipnestControlErrorName.invalidArgs,
      replySerial: message.serial, destination: message.sender,
      body: [.string("Invalid arguments for '\(message.member ?? "?")'")])
  }
}
