import ClipnestCore
import Foundation

/// T-SNIPFB1: shows a transient desktop notification (freedesktop
/// `org.freedesktop.Notifications.Notify`, rendered by GNOME Shell as a banner)
/// for a failed snippet expansion. A notification never takes keyboard focus,
/// so the user's selection stays intact in the app they were typing in.
/// `Process` spawns run on a background queue (never the GTK/main thread), same
/// rule as `SessionLogoutClient`. If neither `gdbus` nor `notify-send` can show
/// it, `fallback` runs (a beep) so the failure is never fully silent.
public enum DesktopNotificationClient {
  // Fixed /usr/bin paths, not PATH lookup (a hijacked PATH must not pick the
  // binary); see `SessionLogoutClient`.
  static let gdbusPath = "/usr/bin/gdbus"
  static let notifySendPath = "/usr/bin/notify-send"
  static let notificationsName = "org.freedesktop.Notifications"
  static let notificationsObjectPath = "/org/freedesktop/Notifications"
  static let notifyMethod = "org.freedesktop.Notifications.Notify"
  static let appName = "Clipnest"
  static let expireMilliseconds = 4000

  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "DesktopNotificationClient")
  private static let processQueue = DispatchQueue(
    label: "com.clipnest.desktopnotificationclient.processQueue", qos: .userInitiated)

  /// Pure - a GVariant text-format string literal (single-quoted, `\` and `'`
  /// escaped, control characters escaped) so arbitrary copy cannot break out of
  /// the argument.
  static func gvariantString(_ text: String) -> String {
    var out = "'"
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\\": out += "\\\\"
      case "'": out += "\\'"
      case "\n": out += "\\n"
      case "\t": out += "\\t"
      default:
        out.unicodeScalars.append(scalar.value < 0x20 ? " " : scalar)
      }
    }
    return out + "'"
  }

  /// Pure - the `gdbus call` argument list (unit-tested; the spawn is not).
  static func gdbusArguments(title: String, body: String) -> [String] {
    [
      "call", "--session", "--dest", notificationsName,
      "--object-path", notificationsObjectPath, "--method", notifyMethod,
      gvariantString(appName), "uint32 0", gvariantString(""),
      gvariantString(title), gvariantString(body), "@as []", "@a{sv} {}",
      "int32 \(expireMilliseconds)",
    ]
  }

  /// Pure - the `notify-send` fallback argument list.
  static func notifySendArguments(title: String, body: String) -> [String] {
    ["--app-name=\(appName)", "--expire-time=\(expireMilliseconds)", "--", title, body]
  }

  /// Fire and forget. `fallback` runs (on the background queue) only if no
  /// notification could be posted.
  public static func notify(title: String, body: String, fallback: @escaping @Sendable () -> Void) {
    processQueue.async {
      if run(gdbusPath, gdbusArguments(title: title, body: body)) { return }
      if run(notifySendPath, notifySendArguments(title: title, body: body)) { return }
      logger.error("desktop notification failed (gdbus and notify-send)")
      fallback()
    }
  }

  /// A wedged notification daemon must not stall later notifications on the
  /// serial queue (D-Bus activation alone can take ~25 s to give up).
  static let processTimeoutSeconds: Double = 5

  private static func run(_ path: String, _ arguments: [String]) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: path) else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      return false
    }
    guard exited.wait(timeout: .now() + processTimeoutSeconds) == .success else {
      process.terminate()
      logger.error("desktop notification helper timed out: \(path)")
      return false
    }
    return process.terminationStatus == 0
  }
}
