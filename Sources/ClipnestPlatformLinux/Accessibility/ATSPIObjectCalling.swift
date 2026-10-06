import Foundation

/// Sends a `DBusMessage` and returns its matching reply, or `nil` on any
/// error/timeout — the seam `ATSPITextAccessor` (and the bus/property
/// helpers) call through, so their request-building/response-parsing logic
/// is unit-testable with a fake that returns canned replies, without a
/// real D-Bus connection. `DBusConnection.call(_:timeout:)` is the real
/// implementation (see that type's `extension DBusConnection:
/// ATSPIObjectCalling {}`).
public protocol ATSPIObjectCalling: Sendable {
  func call(_ message: DBusMessage, timeout: Duration) -> DBusMessage?
}
