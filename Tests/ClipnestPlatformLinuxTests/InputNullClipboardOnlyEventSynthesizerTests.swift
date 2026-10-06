import ClipnestCore
import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("NullClipboardOnlyEventSynthesizer")
struct NullClipboardOnlyEventSynthesizerTests {
  @Test("always reports it cannot synthesize, leaving the clipboard write as the fallback")
  func alwaysThrowsEventPostFailed() {
    let synthesizer = NullClipboardOnlyEventSynthesizer()
    let app = FrontmostAppRef(bundleID: "org.example.App", processIdentifier: 1234)
    #expect(throws: PasteError.eventPostFailed) {
      try synthesizer.synthesizeCommandV(targeting: app)
    }
  }
}
