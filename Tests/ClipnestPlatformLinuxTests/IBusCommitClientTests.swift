// IBusCommitClientTests.swift
//
// T-IBUS-CLIENT: coverage for `IBusCommitClient.unicodeScalarCount(of:)` —
// the ONE piece of arithmetic in this whole client that isn't protocol
// plumbing (`IBusRequests`/`IBusResponses`/`IBusEngineDispatcher` are
// already unit-tested by T-IBUS-WIRE): the wire's own
// `deleteSurroundingText(offsetFromCursor:characterCount:)` accepts
// caller-supplied integers with no type-level enforcement of what unit
// they're counted in (reviewer note, T-IBUS-CLIENT review pass) — so
// whichever count `IBusCommitClient.commit(replacingKeyword:...)` computes
// IS the unit that reaches the wire, and getting it wrong is silent: ASCII
// input can never expose the bug (see below).
//
// `IBusCommitClient` itself owns a live `DBusConnection` with no fakeable
// initializer (same "manual-verify only" precedent as `ShellHelperClient`/
// `ClipnestControlService` — see that type's own top doc comment), so this
// file deliberately does not attempt to construct one; the pure arithmetic
// is what's under test here.

import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("IBusCommitClient.unicodeScalarCount")
struct IBusCommitClientUnicodeScalarCountTests {
  @Test(
    "plain ASCII: grapheme count, UTF-16 count, and Unicode scalar count all agree — this case alone cannot prove which unit is actually used"
  )
  func asciiAllCountsAgree() {
    let keyword = "sig"
    #expect(keyword.count == 3)
    #expect(keyword.utf16.count == 3)
    #expect(IBusCommitClient.unicodeScalarCount(of: keyword) == 3)
  }

  @Test(
    "a combining accent PLUS a non-BMP emoji: grapheme count, UTF-16 count, and Unicode scalar count are all THREE different numbers — only this shape can distinguish which one is actually being used"
  )
  func combiningAccentAndEmojiDistinguishAllThreeCounts() {
    // "e" + U+0301 COMBINING ACUTE ACCENT renders as one visible "é"
    // (one EXTENDED GRAPHEME CLUSTER) but is TWO Unicode scalars; U+1F44D
    // THUMBS UP SIGN is outside the Basic Multilingual Plane, so it is
    // ONE scalar but TWO UTF-16 code units (a surrogate pair).
    let keyword = "e\u{301}\u{1F44D}"

    let graphemeCount = keyword.count
    let utf16Count = keyword.utf16.count
    let scalarCount = IBusCommitClient.unicodeScalarCount(of: keyword)

    #expect(graphemeCount == 2, "'é' (combined) + the emoji = 2 visible characters")
    #expect(utf16Count == 4, "1 (e) + 1 (combining accent) + 2 (surrogate pair) UTF-16 units")
    #expect(scalarCount == 3, "1 (e) + 1 (combining accent) + 1 (emoji) Unicode scalars")

    // The load-bearing assertion: the three counts are pairwise distinct,
    // so this test COULD fail if `unicodeScalarCount` were silently
    // swapped for `.count` or `.utf16.count` — an ASCII-only test cannot
    // make that claim (D95/T-ATSPI1's exact failure shape: a wire-format
    // assumption an ASCII-only fixture could never disprove).
    #expect(Set([graphemeCount, utf16Count, Int(scalarCount)]).count == 3)
  }

  @Test(
    "an empty keyword has a scalar count of zero — a legitimate 'commit with no delete' shape, not an error"
  )
  func emptyKeywordIsZero() {
    #expect(IBusCommitClient.unicodeScalarCount(of: "") == 0)
  }

  @Test(
    "multiple independent emoji each contribute exactly one scalar, regardless of their UTF-16 surrogate-pair width"
  )
  func multipleEmojiCountOnePerScalar() {
    // Three non-BMP emoji: 3 scalars, but 6 UTF-16 units and 3 graphemes
    // (coincidentally equal to the scalar count here, which is exactly
    // why the combining-accent case above is the one that actually
    // distinguishes all three units).
    let keyword = "👍👎🎉"
    #expect(IBusCommitClient.unicodeScalarCount(of: keyword) == 3)
    #expect(keyword.utf16.count == 6)
  }
}

// T-IBUS-REPLACER: coverage for the two pure helpers the corrected
// `SetSurroundingText` gate is built on — `selectedText(in:cursorPos:
// anchorPos:)` (recovering the highlighted keyword with NO synthesized
// keystroke, straight off cursor/anchor Unicode-scalar offsets) and
// `deleteOffsetAndCount(cursorPos:anchorPos:)` (the
// `DeleteSurroundingText` arguments that delete exactly that range). Same
// "an ASCII-only fixture cannot distinguish grapheme/UTF-16/scalar
// indexing" reasoning as `unicodeScalarCount(of:)`'s own tests above (D95/
// T-ATSPI1's exact failure shape) — every non-ASCII test below indexes
// into a string containing a combining accent PLUS a non-BMP emoji, where
// grapheme, UTF-16, and Unicode-scalar counts are all THREE different
// numbers, so a silent swap to `.count`/`.utf16.count`-based indexing
// would produce a DIFFERENT (wrong) substring or a crash, not a
// coincidentally-correct one.
@Suite("IBusCommitClient.selectedText / deleteOffsetAndCount")
struct IBusCommitClientSurroundingTextArithmeticTests {

  // MARK: - selectedText(in:cursorPos:anchorPos:)

  @Test("cursorPos == anchorPos means nothing is highlighted — nil, not the empty string")
  func equalCursorAndAnchorIsNoSelection() {
    #expect(IBusCommitClient.selectedText(in: "hi there", cursorPos: 3, anchorPos: 3) == nil)
  }

  @Test("cursor AFTER anchor (selection extends backward from the cursor) recovers the substring")
  func cursorAfterAnchorRecoversSubstring() {
    // "hi sig there": anchor=3 ("s"), cursor=6 (just past "sig") -> "sig".
    #expect(
      IBusCommitClient.selectedText(in: "hi sig there", cursorPos: 6, anchorPos: 3) == "sig")
  }

  @Test("cursor BEFORE anchor (selection extends forward from the cursor) recovers the substring")
  func cursorBeforeAnchorRecoversSubstring() {
    // "hi sig there": cursor=3, anchor=6 -> SAME substring "sig", opposite
    // drag direction.
    #expect(
      IBusCommitClient.selectedText(in: "hi sig there", cursorPos: 3, anchorPos: 6) == "sig")
  }

  @Test(
    "a combining accent PLUS a non-BMP emoji BEFORE the selection: only Unicode-scalar offsets recover the right substring"
  )
  func nonASCIIPrefixRecoversCorrectSubstringByScalarOffset() {
    // "e\u{301}\u{1F44D}" (3 scalars: e, combining accent, thumbs-up) +
    // "sig" (3 more scalars) + " ok" -> selecting scalars [3,6) must
    // recover "sig", not something shifted by grapheme (2) or UTF-16 (4)
    // counting of the prefix instead.
    let text = "e\u{301}\u{1F44D}sig ok"
    #expect(IBusCommitClient.selectedText(in: text, cursorPos: 6, anchorPos: 3) == "sig")
  }

  @Test("out-of-range offsets (a malformed/stale snapshot) degrade to nil, never a crash")
  func outOfRangeOffsetsAreNilNotACrash() {
    #expect(IBusCommitClient.selectedText(in: "hi", cursorPos: 0, anchorPos: 99) == nil)
  }

  // MARK: - deleteOffsetAndCount(cursorPos:anchorPos:)

  @Test("cursor AFTER anchor: offset is negative, reaching back to the anchor")
  func cursorAfterAnchorNegativeOffset() {
    let (offset, count) = IBusCommitClient.deleteOffsetAndCount(cursorPos: 6, anchorPos: 3)
    #expect(offset == -3)
    #expect(count == 3)
  }

  @Test("cursor BEFORE anchor: offset is zero, count reaches forward to the anchor")
  func cursorBeforeAnchorZeroOffset() {
    let (offset, count) = IBusCommitClient.deleteOffsetAndCount(cursorPos: 3, anchorPos: 6)
    #expect(offset == 0)
    #expect(count == 3)
  }

  @Test("equal cursor/anchor: zero-length delete, never negative or crashing")
  func equalCursorAndAnchorZeroLength() {
    let (offset, count) = IBusCommitClient.deleteOffsetAndCount(cursorPos: 5, anchorPos: 5)
    #expect(offset == 0)
    #expect(count == 0)
  }
}
