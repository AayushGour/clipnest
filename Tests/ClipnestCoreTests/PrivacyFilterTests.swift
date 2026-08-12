import AppKit
import Foundation
import Testing

@testable import ClipnestCore

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
}
