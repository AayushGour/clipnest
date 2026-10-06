import Foundation
import Synchronization

/// Tracks "which accessible object is currently focused" by LISTENING for
/// `object:state-changed:focused` events, rather than tree-walking every
/// window on demand — a walk is O(n) over the whole accessibility tree and
/// takes hundreds of ms, far too slow for a hotkey-driven snippet
/// expansion.
///
/// Registers with `org.a11y.atspi.Registry` (`RegisterEvent`) AND adds a
/// plain `org.freedesktop.DBus.AddMatch` rule for
/// `org.a11y.atspi.Event.Object.StateChanged` on its own connection —
/// `RegisterEvent` tells `at-spi2-registryd` this client wants the event
/// class forwarded to it at all; `AddMatch` is what actually makes THIS
/// connection receive the forwarded signal (real `libatspi` clients do
/// both, per the AT-SPI2 D-Bus client library's own registration path).
///
/// Manual-verify only: there is no a11y bus in the CI container this ships
/// to. Only the pure parsing it delegates to
/// (`ATSPIFocusEventParsing.focusedTarget(from:)`) is unit-tested.
public final class ATSPIFocusTracker: @unchecked Sendable {
  private let connection: DBusConnection
  private let readTimeout: Duration
  private let cache = Mutex<(busName: String, objectPath: String)?>(nil)
  private var readerThread: Thread?

  public init(connection: DBusConnection, readTimeout: Duration = .seconds(1)) {
    self.connection = connection
    self.readTimeout = readTimeout
  }

  /// Sends the registration calls, then starts the background signal-read
  /// loop. Call once, after connecting to the a11y bus address returned by
  /// `AccessibilityBusResolver.resolveAddress`.
  public func start() {
    _ = connection.call(
      ATSPIRequests.registerFocusEvent(serial: connection.allocateSerial()),
      timeout: ATSPIConstants.callTimeout)
    _ = connection.call(
      ATSPIRequests.addFocusMatch(serial: connection.allocateSerial()),
      timeout: ATSPIConstants.callTimeout)

    let thread = Thread { [weak self] in self?.readLoop() }
    thread.name = "ATSPIFocusTracker"
    readerThread = thread
    thread.start()
  }

  /// The most recently observed focused accessible, or `nil` if nothing
  /// has been observed yet (e.g. `start()` hasn't run, or no app has
  /// reported a focus change since).
  public func currentFocusedObject() -> (busName: String, objectPath: String)? {
    cache.withLock { $0 }
  }

  private func readLoop() {
    while true {
      guard let message = connection.receiveOneMessage(timeout: readTimeout) else { continue }
      guard let target = ATSPIFocusEventParsing.focusedTarget(from: message) else { continue }
      cache.withLock { $0 = target }
    }
  }
}
