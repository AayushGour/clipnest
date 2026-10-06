import Testing

@testable import ClipnestGTK

/// T-WB1-GTKBUMP: unit-tests the pure clipboard-stability-notice decision
/// logic (`GTKRuntimeVersion`/`GTKClipboardCrashNoticePresentation`),
/// separated from GTK widget code and from the live FFI read
/// (`GTKClipboardCrashNoticeDetection`, untestable — see that file's doc
/// comment) — mirrors `GTKPermissionsTabPresentationTests`'s identical
/// "pure logic behind a GTK tab, tested directly with injected values"
/// split. Every version number below is injected — none of this reads a
/// live GTK runtime, so both the "affected" (jammy, 4.6.9) and "fixed"
/// (noble, 4.14.5) cases are fully covered here even though only the
/// affected one is actually installed in CI's `swift:6.0-jammy` container.
@Suite("GTKClipboardCrashNoticePresentation")
struct GTKClipboardCrashNoticePresentationTests {
  @Test("Ubuntu 22.04's real shipped version (4.6.9) is affected")
  func jammyVersionIsAffected() {
    let version = GTKRuntimeVersion(major: 4, minor: 6, micro: 9)
    #expect(version.isAffectedByX11ClipboardCrash)
  }

  @Test("Ubuntu 24.04's real shipped version (4.14.5) is fixed")
  func nobleVersionIsFixed() {
    let version = GTKRuntimeVersion(major: 4, minor: 14, micro: 5)
    #expect(!version.isAffectedByX11ClipboardCrash)
  }

  @Test("Exactly 4.10.0, the fixed version itself, is not affected")
  func exactlyFixedVersionIsNotAffected() {
    #expect(!GTKRuntimeVersion(major: 4, minor: 10, micro: 0).isAffectedByX11ClipboardCrash)
  }

  @Test("The last affected minor (4.9.x) is still affected regardless of micro")
  func lastAffectedMinorIsAffected() {
    #expect(GTKRuntimeVersion(major: 4, minor: 9, micro: 99).isAffectedByX11ClipboardCrash)
  }

  @Test("Micro version never changes the verdict within an affected minor")
  func microVersionDoesNotMatterWithinAffectedMinor() {
    #expect(GTKRuntimeVersion(major: 4, minor: 6, micro: 0).isAffectedByX11ClipboardCrash)
    #expect(GTKRuntimeVersion(major: 4, minor: 6, micro: 999).isAffectedByX11ClipboardCrash)
  }

  @Test("A hypothetical future major version (5.0.0) is not affected")
  func futureMajorVersionIsNotAffected() {
    #expect(!GTKRuntimeVersion(major: 5, minor: 0, micro: 0).isAffectedByX11ClipboardCrash)
  }

  @Test("An affected version on X11 shows the notice")
  func affectedVersionOnX11Shows() {
    let info = GTKClipboardCrashNoticeInfo(
      runtimeVersion: GTKRuntimeVersion(major: 4, minor: 6, micro: 9), isX11Backend: true)
    #expect(GTKClipboardCrashNoticePresentation.shouldShow(for: info))
  }

  @Test("An affected version on Wayland does NOT show — the crash is X11-only")
  func affectedVersionOnWaylandDoesNotShow() {
    let info = GTKClipboardCrashNoticeInfo(
      runtimeVersion: GTKRuntimeVersion(major: 4, minor: 6, micro: 9), isX11Backend: false)
    #expect(!GTKClipboardCrashNoticePresentation.shouldShow(for: info))
  }

  @Test("A fixed version on X11 does NOT show — 4.10+ already has the fix")
  func fixedVersionOnX11DoesNotShow() {
    let info = GTKClipboardCrashNoticeInfo(
      runtimeVersion: GTKRuntimeVersion(major: 4, minor: 14, micro: 5), isX11Backend: true)
    #expect(!GTKClipboardCrashNoticePresentation.shouldShow(for: info))
  }

  @Test("A fixed version on Wayland does NOT show either")
  func fixedVersionOnWaylandDoesNotShow() {
    let info = GTKClipboardCrashNoticeInfo(
      runtimeVersion: GTKRuntimeVersion(major: 4, minor: 14, micro: 5), isX11Backend: false)
    #expect(!GTKClipboardCrashNoticePresentation.shouldShow(for: info))
  }

  @Test(
    "The body text is non-alarming: names the real version, blames the system GTK, not Clipnest"
  )
  func bodyTextIsAccurateAndNonAlarming() {
    let info = GTKClipboardCrashNoticeInfo(
      runtimeVersion: GTKRuntimeVersion(major: 4, minor: 6, micro: 9), isX11Backend: true)
    let text = GTKClipboardCrashNoticePresentation.bodyText(for: info)
    #expect(text.contains("4.6.9"))
    #expect(text.contains("GTK 4.10"))
    #expect(text.contains("Ubuntu 24.04"))
    #expect(text.contains("not in Clipnest"))
    #expect(text.contains("clipboard history is never affected"))
  }

  @Test("GTKRuntimeVersion.description formats as major.minor.micro")
  func descriptionFormatsAsDottedTriple() {
    #expect(GTKRuntimeVersion(major: 4, minor: 6, micro: 9).description == "4.6.9")
  }
}
