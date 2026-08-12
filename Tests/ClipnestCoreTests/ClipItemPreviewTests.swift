import Foundation
import Testing

@testable import ClipnestCore

@Suite("ClipItem preview eligibility")
struct ClipItemPreviewTests {
  private func item(_ kind: ItemKind, _ preview: String) -> ClipItem {
    ClipItem(kind: kind, previewText: preview, contentHash: "h")
  }

  @Test("Every kind is preview-worthy (files show name/size/path, no file access)")
  func allKindsWorthy() {
    #expect(item(.text, "hello").isPreviewWorthy)
    #expect(item(.link, "https://a.co").isPreviewWorthy)
    #expect(item(.richText, "styled").isPreviewWorthy)
    #expect(item(.image, "Image, 4×4").isPreviewWorthy)
    #expect(item(.file, "setup-team.py").isPreviewWorthy)
  }
}
