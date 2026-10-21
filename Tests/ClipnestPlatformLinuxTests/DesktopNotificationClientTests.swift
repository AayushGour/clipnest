import Testing

@testable import ClipnestLinuxAppKit

/// T-SNIPFB1: the pure parts of `DesktopNotificationClient` (argument lists and
/// GVariant quoting). The real spawn needs a desktop session.
@Suite("DesktopNotificationClient")
struct DesktopNotificationClientTests {
  @Test("gvariantString single-quotes and escapes quotes, backslashes, newlines")
  func quoting() {
    #expect(DesktopNotificationClient.gvariantString("plain") == "'plain'")
    #expect(DesktopNotificationClient.gvariantString("it's") == "'it\\'s'")
    #expect(DesktopNotificationClient.gvariantString("a\\b") == "'a\\\\b'")
    #expect(DesktopNotificationClient.gvariantString("a\nb") == "'a\\nb'")
    #expect(DesktopNotificationClient.gvariantString("") == "''")
  }

  @Test("Notify call carries app name, title, body and a finite timeout")
  func gdbusArguments() {
    let args = DesktopNotificationClient.gdbusArguments(title: "T", body: "B 'x'")
    #expect(args.contains("org.freedesktop.Notifications.Notify"))
    #expect(args.contains("--session"))
    #expect(args.contains("'T'"))
    #expect(args.contains("'B \\'x\\''"))
    #expect(args.last == "int32 4000")
  }

  @Test("notify-send fallback terminates options before the text")
  func notifySendArguments() {
    let args = DesktopNotificationClient.notifySendArguments(title: "-t", body: "b")
    #expect(args.firstIndex(of: "--")! < args.firstIndex(of: "-t")!)
  }
}
