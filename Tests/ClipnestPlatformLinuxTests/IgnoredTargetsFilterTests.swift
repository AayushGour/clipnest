import Testing

@testable import ClipnestPlatformLinux

@Suite("IgnoredTargetsFilter")
struct IgnoredTargetsFilterTests {
  @Test("Strips every explicitly-named negotiation/bookkeeping target")
  func stripsExactlyNamedTargets() {
    let filtered = IgnoredTargetsFilter.filter([
      "TARGETS", "TIMESTAMP", "MULTIPLE", "SAVE_TARGETS", "DELETE", "_NETSCAPE_URL",
      "text/x-moz-url-priv", "text/plain",
    ])
    #expect(filtered == ["text/plain"])
  }

  @Test("Strips every application/x-qt-* target by prefix")
  func stripsQtPrefixedTargets() {
    let filtered = IgnoredTargetsFilter.filter([
      "application/x-qt-image-literal", "application/x-qt-windows-mime;value=\"Foo\"",
      "text/html",
    ])
    #expect(filtered == ["text/html"])
  }

  @Test("Never strips a real content MIME type")
  func neverStripsRealContent() {
    let real = ["text/html", "image/png", "text/uri-list", "text/plain;charset=utf-8"]
    #expect(IgnoredTargetsFilter.filter(real) == real)
  }
}
