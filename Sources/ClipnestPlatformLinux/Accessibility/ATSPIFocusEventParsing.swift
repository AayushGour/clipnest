import Foundation

/// Pure parsing of an incoming `org.a11y.atspi.Event.Object.StateChanged`
/// signal into "which accessible object just gained keyboard focus," if
/// that's what it is.
///
/// The signal's body signature is `siiva{sv}` (confirmed against
/// `at-spi2-core`'s `xml/Event.xml`): `state` (string, e.g. `"focused"`),
/// `enabled` (int32, 1 = gained / 0 = lost), a second int32 detail this
/// module doesn't use, a variant, and a `properties` dict this module also
/// doesn't need — `DBusMessage.decode` still parses the full signature so
/// the byte stream stays correctly framed, but only `body[0]`/`body[1]`
/// are inspected here.
///
/// The identity of the object that changed state is NOT in the body at
/// all: it's the message's own header fields — `sender` (the emitting
/// app's unique bus name, populated truthfully by the bus daemon, which
/// apps cannot forge) and `path` (the accessible object's own path on that
/// app's connection).
enum ATSPIFocusEventParsing {
  static func focusedTarget(from message: DBusMessage) -> (busName: String, objectPath: String)? {
    guard message.type == .signal, message.interface == ATSPIInterface.event,
      message.member == ATSPIMember.stateChanged, let sender = message.sender,
      let path = message.path, message.body.count >= 2,
      case .string(let state) = message.body[0], state == ATSPIStateName.focused,
      case .int32(let enabled) = message.body[1], enabled == 1
    else { return nil }
    return (sender, path)
  }
}
