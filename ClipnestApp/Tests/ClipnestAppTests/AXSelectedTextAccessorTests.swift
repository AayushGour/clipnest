// AXSelectedTextAccessorTests.swift
//
// Covers the two pure decision helpers in `AXSelectedTextAccessor` — the
// only logic in the T-ELEC1/T-AXTRUST1/T-SAFARI1 fixes that doesn't require
// a real AX call (see D97-D99 in project-context.md):
//   - `isTrustworthy(role:)` — a role ALLOWLIST (T-AXTRUST1), replacing
//     T-ELEC1's original single-entry `AXWebArea` denylist. Tests below
//     include roles never seen in any prior fix ("AXGroup", "AXUnknown") to
//     prove this is a real generalization, not a rename of the old guard.
//   - `rangeChanged(before:after:)` — the write-verification signal behind
//     T-SAFARI1's fix for Safari/WebKit's phantom-success write.
// Driving real `AXUIElement`s/`AXValue`s is a system boundary verified by
// hand, not faked here — same precedent as `HotkeyManagerTests`.

import ApplicationServices
import Testing

@testable import Clipnest

@Suite("AXSelectedTextAccessor.isTrustworthy")
struct AXSelectedTextAccessorIsTrustworthyTests {

  @Test("an AXWebArea-rooted selection is not trusted")
  func webAreaIsNotTrusted() {
    #expect(!AXSelectedTextAccessor.isTrustworthy(role: "AXWebArea"))
  }

  @Test(
    "a real text control's role is trusted",
    arguments: [
      "AXTextField", "AXTextArea", "AXComboBox", "AXStaticText", "AXSecureTextField",
    ])
  func realTextControlIsTrusted(role: String) {
    #expect(AXSelectedTextAccessor.isTrustworthy(role: role))
  }

  // T-AXTRUST1: these two roles were never mentioned by T-ELEC1's denylist
  // (which only ever knew about "AXWebArea") and are not synonyms for it —
  // asserting them false only passes if `isTrustworthy` is a genuine
  // allowlist (untrusted unless recognized), not the old guard renamed
  // (untrusted only if literally "AXWebArea"). These synthetic cases have a
  // real-world counterpart: a 2026-09 cross-app AX-fidelity survey found Tor
  // Browser (Gecko) reports exactly this shape of unrecognized role
  // (AXGroup/AXUnknown) and fails HONESTLY on both read and write (a real
  // `AXError`, no phantom success) — the allowlist correctly routes it to
  // the clipboard fallback rather than trusting an unrecognized container.
  @Test(
    "a previously-unseen synthetic role is not trusted",
    arguments: ["AXGroup", "AXUnknown"])
  func unseenSyntheticRoleIsNotTrusted(role: String) {
    #expect(!AXSelectedTextAccessor.isTrustworthy(role: role))
  }

  // T-AXTRUST1/D99: flipped from T-ELEC1's original "trust it" — the single
  // highest-leverage line change in this task. An unreadable role is
  // uncertainty, and D97's contract routes uncertainty to the clipboard
  // fallback rather than trusting it.
  @Test("an unreadable role (nil) is NOT trusted — flipped from trusted in T-ELEC1")
  func unreadableRoleIsNotTrusted() {
    #expect(!AXSelectedTextAccessor.isTrustworthy(role: nil))
  }
}

@Suite("AXSelectedTextAccessor.rangeChanged")
struct AXSelectedTextAccessorRangeChangedTests {

  @Test("a range that moved after a .success write is a verified change")
  func movedRangeIsChanged() {
    let before = CFRange(location: 10, length: 4)
    let after = CFRange(location: 10, length: 9)
    #expect(AXSelectedTextAccessor.rangeChanged(before: before, after: after))
  }

  @Test("a range whose location shifted is a verified change")
  func shiftedLocationIsChanged() {
    let before = CFRange(location: 10, length: 4)
    let after = CFRange(location: 19, length: 0)
    #expect(AXSelectedTextAccessor.rangeChanged(before: before, after: after))
  }

  // T-SAFARI1's core bug: Safari/WebKit returns `.success` while the field
  // is provably unchanged. An identical before/after range must NOT be
  // treated as a real write.
  @Test("an identical range is an unverified phantom write")
  func identicalRangeIsNotChanged() {
    let range = CFRange(location: 10, length: 4)
    #expect(!AXSelectedTextAccessor.rangeChanged(before: range, after: range))
  }

  @Test("an unreadable range before the write is an unverified phantom write")
  func unreadableBeforeIsNotChanged() {
    let after = CFRange(location: 10, length: 9)
    #expect(!AXSelectedTextAccessor.rangeChanged(before: nil, after: after))
  }

  @Test("an unreadable range after the write is an unverified phantom write")
  func unreadableAfterIsNotChanged() {
    let before = CFRange(location: 10, length: 4)
    #expect(!AXSelectedTextAccessor.rangeChanged(before: before, after: nil))
  }

  @Test("unreadable both before and after is an unverified phantom write")
  func unreadableBothIsNotChanged() {
    #expect(!AXSelectedTextAccessor.rangeChanged(before: nil, after: nil))
  }
}
