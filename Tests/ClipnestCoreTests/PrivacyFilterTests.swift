import Foundation
import Testing

@testable import ClipnestCore

// P2-A (Linux port): this suite only ever speaks `ClipMediaType` (never
// `NSPasteboard` itself), so it needs no `import AppKit` and runs on every
// platform. The concealed/transient marker guard test below in particular
// MUST keep running on both — those raw UTI values are security-critical
// (see that test's own doc comment).
@Suite("PrivacyFilter")
struct PrivacyFilterTests {
  private let concealedType = PrivacyFilter.concealedPasteboardType
  private let transientType = PrivacyFilter.transientPasteboardType

  @Test("Accepts a normal capture from a non-excluded app")
  func acceptsHappyPath() {
    let filter = PrivacyFilter()

    let result = filter.shouldCapture(
      availableTypes: [.string],
      sourceBundleID: "com.apple.TextEdit",
      isPaused: false
    )

    #expect(result == true)
  }

  @Test("Rejects unconditionally when the concealed marker is present")
  func rejectsConcealedMarker() {
    let filter = PrivacyFilter()

    let result = filter.shouldCapture(
      availableTypes: [.string, concealedType],
      sourceBundleID: "com.apple.TextEdit",
      isPaused: false,
      customExcludedBundleIDs: []
    )

    #expect(result == false)
  }

  @Test(
    "Concealed marker cannot be bypassed even with a non-paused, non-excluded, empty-custom-list call"
  )
  func concealedMarkerIsUnbypassable() {
    let filter = PrivacyFilter()

    // Every other parameter is set to its most permissive value.
    let result = filter.shouldCapture(
      availableTypes: [concealedType],
      sourceBundleID: nil,
      isPaused: false,
      customExcludedBundleIDs: []
    )

    #expect(result == false)
  }

  @Test("Rejects unconditionally when the transient marker is present")
  func rejectsTransientMarker() {
    let filter = PrivacyFilter()

    let result = filter.shouldCapture(
      availableTypes: [.string, transientType],
      sourceBundleID: "com.apple.TextEdit",
      isPaused: false
    )

    #expect(result == false)
  }

  @Test("Rejects everything while paused")
  func rejectsWhilePaused() {
    let filter = PrivacyFilter()

    let result = filter.shouldCapture(
      availableTypes: [.string],
      sourceBundleID: "com.apple.TextEdit",
      isPaused: true
    )

    #expect(result == false)
  }

  #if os(macOS)
    @Test("Rejects a built-in password-manager bundle ID")
    func rejectsBuiltInExcludedApp() {
      let filter = PrivacyFilter()

      let result = filter.shouldCapture(
        availableTypes: [.string],
        sourceBundleID: "com.1password.1password",
        isPaused: false
      )

      #expect(result == false)
    }
  #else
    // T-BUG3 (parity-audit bug #3): the macOS bundle-ID list above can never
    // match on Linux — see `PrivacyFilter.builtInExcludedBundleIDs`'s
    // `#else` branch doc comment for the Linux identifier list and its
    // per-entry verification. This is the Linux equivalent of the macOS
    // test above, not an addition to it — same assertion shape, a real
    // Linux identifier instead of a macOS bundle ID.
    @Test("Rejects a built-in Linux password-manager identifier")
    func rejectsBuiltInExcludedApp() {
      let filter = PrivacyFilter()

      let result = filter.shouldCapture(
        availableTypes: [.string],
        sourceBundleID: "org.keepassxc.KeePassXC",
        isPaused: false
      )

      #expect(result == false)
    }

    @Test(
      "Rejects a built-in Linux identifier reported via WM_CLASS's differently-cased class component"
    )
    func rejectsBuiltInExcludedAppRegardlessOfCase() {
      let filter = PrivacyFilter()

      // KeePassXC's real WM_CLASS is lowercase ("keepassxc") — a window
      // manager or Qt build that reports it capitalized must still match.
      let result = filter.shouldCapture(
        availableTypes: [.string],
        sourceBundleID: "KeePassXC",
        isPaused: false
      )

      #expect(result == false)
    }

    @Test(
      "A Linux app name that merely CONTAINS an excluded identifier as a substring is not excluded"
    )
    func substringOfExcludedIdentifierDoesNotFalselyMatch() {
      let filter = PrivacyFilter()

      // Case-insensitive comparison must still be a FULL match, not a
      // substring/contains check — "notkeepassxc" must not be excluded
      // just because it contains "keepassxc".
      let result = filter.shouldCapture(
        availableTypes: [.string],
        sourceBundleID: "notkeepassxc",
        isPaused: false
      )

      #expect(result == true)
    }

    @Test("Every documented Linux built-in identifier actually excludes a capture")
    func everyDocumentedLinuxIdentifierExcludes() {
      let filter = PrivacyFilter()

      // Pins each literal string added for T-BUG3 individually, so a typo
      // in any ONE entry (which would otherwise silently just mean that
      // one password manager isn't actually protected — exactly this
      // task's own warning) fails a test instead of shipping unnoticed.
      for identifier in PrivacyFilter.builtInExcludedBundleIDs {
        let result = filter.shouldCapture(
          availableTypes: [.string],
          sourceBundleID: identifier,
          isPaused: false
        )
        #expect(result == false, "expected \(identifier) to be excluded")
      }
    }
  #endif

  @Test("Rejects a caller-supplied custom excluded bundle ID")
  func rejectsCustomExcludedApp() {
    let filter = PrivacyFilter()

    let result = filter.shouldCapture(
      availableTypes: [.string],
      sourceBundleID: "com.example.SecretsApp",
      isPaused: false,
      customExcludedBundleIDs: ["com.example.SecretsApp"]
    )

    #expect(result == false)
  }

  @Test("Custom excluded list does not affect apps outside it")
  func customExclusionsDoNotLeak() {
    let filter = PrivacyFilter()

    let result = filter.shouldCapture(
      availableTypes: [.string],
      sourceBundleID: "com.apple.TextEdit",
      isPaused: false,
      customExcludedBundleIDs: ["com.example.SecretsApp"]
    )

    #expect(result == true)
  }

  // P1-T1: temporary guard test for the `ClipMediaType` refactor — the
  // concealed/transient markers are security-critical (they silently
  // disable password-manager filtering if the raw UTI string is ever
  // wrong), so this pins their exact raw values independently of whatever
  // `ClipMediaType`/`NSPasteboard.PasteboardType` machinery produces them.
  @Test("Concealed and transient marker raw values are exactly the org.nspasteboard UTIs")
  func concealedAndTransientMarkersHaveExactRawValues() {
    #expect(concealedType.rawValue == "org.nspasteboard.ConcealedType")
    #expect(transientType.rawValue == "org.nspasteboard.TransientType")
  }
}
