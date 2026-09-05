import ClipnestPlatformLinux
import Foundation

@testable import ClipnestLinuxAppKit

/// A scripted `DBusCalling` fake — no real socket, no real bus. Replies
/// are consumed in the order they're enqueued; a call made with nothing
/// queued returns `nil` (mirrors `DBusConnection.call`'s own timeout
/// contract). Shared by every `ClipnestLinuxApp` test file in this target
/// that needs to exercise a connection-owning type
/// (`SingleInstance`/`ShellHelperClient`) without a real bus — per this
/// task's "do NOT write tests needing a real bus" constraint.
final class FakeDBusCalling: DBusCalling, @unchecked Sendable {
  private(set) var sentMessages: [DBusMessage] = []
  private var scriptedReplies: [DBusMessage?]

  init(scriptedReplies: [DBusMessage?] = []) {
    self.scriptedReplies = scriptedReplies
  }

  func call(_ message: DBusMessage, timeout: Duration) -> DBusMessage? {
    sentMessages.append(message)
    guard !scriptedReplies.isEmpty else { return nil }
    return scriptedReplies.removeFirst()
  }
}

/// Builds a `METHOD_RETURN` reply carrying `body`, matching the shape
/// every real `DBusConnection.call` reply has — a small shared helper so
/// every test file constructs canned replies identically.
func fakeMethodReturn(body: [DBusValue] = []) -> DBusMessage {
  DBusMessage(type: .methodReturn, serial: 1, replySerial: 1, body: body)
}
