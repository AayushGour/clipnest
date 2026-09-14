// IBusCommitPolicyTests.swift
//
// T-IBUS-REPLACER: `IBusCommitPolicy` is deliberately an EMPTY exclude
// list (see that type's own doc comment for why) — these tests pin that
// "eligible by default, for everything, including nil" contract so a
// future accidental non-empty literal (or a flipped default) fails loudly
// rather than silently narrowing snippet expansion's IBus tier.

import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("IBusCommitPolicy")
struct IBusCommitPolicyTests {
  @Test("the exclude list is empty — no app class is excluded from the IBus commit tier")
  func excludedIdentifiersIsEmpty() {
    #expect(IBusCommitPolicy.excludedIdentifiers.isEmpty)
  }

  @Test("a nil app identifier is eligible — never assume exclusion without a positive match")
  func nilIdentifierIsEligible() {
    #expect(IBusCommitPolicy.isEligible(appIdentifier: nil))
  }

  @Test("an arbitrary, unrecognized app identifier is eligible")
  func unrecognizedIdentifierIsEligible() {
    #expect(IBusCommitPolicy.isEligible(appIdentifier: "org.gnome.TextEditor"))
  }

  @Test(
    "a terminal-class identifier (TerminalAppRegistry's own list) is STILL eligible — this tier is uniquely good at terminals, unlike the clipboard tier, so it must never gain a terminal-decline check of its own"
  )
  func terminalIdentifierIsStillEligible() {
    #expect(IBusCommitPolicy.isEligible(appIdentifier: "org.gnome.Terminal"))
    #expect(IBusCommitPolicy.isEligible(appIdentifier: "konsole"))
  }
}
