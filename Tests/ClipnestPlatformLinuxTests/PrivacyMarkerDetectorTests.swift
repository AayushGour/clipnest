import Testing

@testable import ClipnestPlatformLinux

@Suite("PrivacyMarkerDetector")
struct PrivacyMarkerDetectorTests {
  @Test("Accepts a normal MIME list with no privacy marker")
  func acceptsNormalList() {
    #expect(!PrivacyMarkerDetector.isConcealed(mimeTypes: ["text/plain;charset=utf-8"]))
  }

  @Test("Detects the KDE password-manager hint (KeePassXC/Bitwarden/Klipper/CopyQ convention)")
  func detectsKdePasswordManagerHint() {
    #expect(
      PrivacyMarkerDetector.isConcealed(
        mimeTypes: ["text/plain;charset=utf-8", "x-kde-passwordManagerHint"]))
  }

  @Test("Detects application/x-nspasteboard-concealed-type")
  func detectsNspasteboardConcealedMimeType() {
    #expect(
      PrivacyMarkerDetector.isConcealed(mimeTypes: ["application/x-nspasteboard-concealed-type"]))
  }

  @Test("Detects the literal org.nspasteboard.ConcealedType UTI seen from ports")
  func detectsLiteralNspasteboardUTI() {
    #expect(PrivacyMarkerDetector.isConcealed(mimeTypes: ["org.nspasteboard.ConcealedType"]))
  }

  @Test("Presence-only: detection never depends on any other MIME type present alongside it")
  func presenceOnlyRegardlessOfOtherTypes() {
    #expect(
      PrivacyMarkerDetector.isConcealed(
        mimeTypes: ["text/html", "image/png", "x-kde-passwordManagerHint"]))
  }

  @Test("Empty MIME list is never concealed")
  func emptyListIsNotConcealed() {
    #expect(!PrivacyMarkerDetector.isConcealed(mimeTypes: []))
  }
}
