import Foundation
import Testing

#if os(macOS)
  import AppKit

  @testable import ClipnestCore

  @Suite("MacEditableRichText")
  @MainActor
  struct MacEditableRichTextTests {
    private typealias Rich = MacEditableRichText

    private func plain(_ text: String) -> NSMutableAttributedString {
      NSMutableAttributedString(string: text, attributes: Rich.defaultAttributes)
    }

    private func isBold(_ s: NSAttributedString, at i: Int) -> Bool {
      let font = s.attribute(.font, at: i, effectiveRange: nil) as? NSFont
      return font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
    }

    private func isItalic(_ s: NSAttributedString, at i: Int) -> Bool {
      let font = s.attribute(.font, at: i, effectiveRange: nil) as? NSFont
      return font.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false
    }

    private func isUnderlined(_ s: NSAttributedString, at i: Int) -> Bool {
      let v = s.attribute(.underlineStyle, at: i, effectiveRange: nil) as? Int ?? 0
      return v != 0
    }

    @Test func plainItemLoadsWithoutFormattingAndIsNotLossy() {
      let loaded = Rich.load(rtf: nil, plainText: "hello")
      #expect(loaded.attributed.string == "hello")
      #expect(!loaded.isLossy)
      #expect(!Rich.hasFormatting(loaded.attributed))
    }

    @Test func boldRangeMakesHasFormattingTrue_removingItMakesItFalse() {
      let s = plain("hello world")
      Rich.toggle(.bold, in: s, range: NSRange(location: 0, length: 5))
      #expect(Rich.hasFormatting(s))
      Rich.toggle(.bold, in: s, range: NSRange(location: 0, length: 5))
      #expect(!Rich.hasFormatting(s))
    }

    @Test func toggleBoldTwiceOnSameRangeRestoresOriginal() {
      let s = plain("hello world")
      let original = NSAttributedString(attributedString: s)
      Rich.toggle(.bold, in: s, range: NSRange(location: 2, length: 6))
      #expect(isBold(s, at: 3))
      Rich.toggle(.bold, in: s, range: NSRange(location: 2, length: 6))
      #expect(!isBold(s, at: 3))
      #expect(s.isEqual(to: original))
    }

    @Test func toggleUnderlineAndItalicApplyOnlyToRange() {
      let s = plain("abcdef")
      Rich.toggle(.underline, in: s, range: NSRange(location: 1, length: 2))
      Rich.toggle(.italic, in: s, range: NSRange(location: 3, length: 2))
      #expect(!isUnderlined(s, at: 0) && isUnderlined(s, at: 1) && isUnderlined(s, at: 2))
      #expect(!isUnderlined(s, at: 3))
      #expect(!isItalic(s, at: 2) && isItalic(s, at: 3) && isItalic(s, at: 4))
      #expect(!isItalic(s, at: 5))
    }

    @Test func toggleAddsWhenOnlyPartOfRangeHasTrait() {
      let s = plain("abcd")
      Rich.toggle(.bold, in: s, range: NSRange(location: 0, length: 2))
      Rich.toggle(.bold, in: s, range: NSRange(location: 0, length: 4))
      #expect((0..<4).allSatisfy { isBold(s, at: $0) })
    }

    @Test func toggleOnEmptyOrOutOfBoundsRangeIsNoOp() {
      let s = plain("abc")
      let original = NSAttributedString(attributedString: s)
      Rich.toggle(.bold, in: s, range: NSRange(location: 1, length: 0))
      Rich.toggle(.bold, in: s, range: NSRange(location: 5, length: 3))
      #expect(s.isEqual(to: original))
    }

    @Test func rtfRoundTripPreservesBoldItalicUnderlineColor() throws {
      let s = plain("boldital under red")
      Rich.toggle(.bold, in: s, range: NSRange(location: 0, length: 4))
      Rich.toggle(.italic, in: s, range: NSRange(location: 4, length: 4))
      Rich.toggle(.underline, in: s, range: NSRange(location: 9, length: 5))
      s.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 15, length: 3))
      let data = try #require(Rich.rtf(from: s))
      let loaded = Rich.load(rtf: data, plainText: "ignored")
      let r = loaded.attributed
      #expect(r.string == s.string)
      #expect(isBold(r, at: 0) && !isBold(r, at: 5))
      #expect(isItalic(r, at: 5) && !isItalic(r, at: 0))
      #expect(isUnderlined(r, at: 10) && !isUnderlined(r, at: 0))
      let color = r.attribute(.foregroundColor, at: 16, effectiveRange: nil) as? NSColor
      #expect(color?.usingColorSpace(.sRGB)?.redComponent ?? 0 > 0.9)
      #expect(Rich.hasFormatting(r))
    }

    @Test func attachmentMarksItemLossy() {
      let s = NSMutableAttributedString(attributedString: plain("a"))
      s.append(NSAttributedString(attachment: NSTextAttachment()))
      #expect(Rich.isLossy(s))
      #expect(Rich.hasFormatting(s))
    }

    @Test func paragraphStyleWithListOrCustomTabsIsNotNeutral() {
      #expect(Rich.isNeutral(NSParagraphStyle.default))
      let list = NSMutableParagraphStyle()
      list.textLists = [NSTextList(markerFormat: .disc, options: 0)]
      #expect(!Rich.isNeutral(list))
      let tabs = NSMutableParagraphStyle()
      tabs.tabStops = [NSTextTab(textAlignment: .left, location: 77)]
      #expect(!Rich.isNeutral(tabs))
    }

    @Test func unreadableRTFFallsBackToPlainTextAndIsLossy() {
      let loaded = Rich.load(rtf: Data([0x00, 0x01, 0xFF, 0x42]), plainText: "preview")
      #expect(loaded.attributed.string == "preview")
      #expect(loaded.isLossy)
      #expect(!Rich.hasFormatting(loaded.attributed))
    }

    @Test func untouchedRichItemRoundTripsLosslessly() {
      let rtf = Data(
        #"{\rtf1\ansi{\fonttbl\f0\fswiss Helvetica;}\f0\fs24 plain \b bold\b0  \i ital\i0 }"#.utf8)
      let loaded = Rich.load(rtf: rtf, plainText: "x")
      #expect(loaded.attributed.string == "plain bold ital")
      #expect(!loaded.isLossy)
      #expect(Rich.hasFormatting(loaded.attributed))
    }

    @Test func activeTraitsFollowSelectionOrTypingStyleWhenCaretOnly() {
      let s = plain("hello world")
      Rich.toggle(.bold, in: s, range: NSRange(location: 0, length: 5))
      let typing = Rich.defaultAttributes
      let boldWord = NSRange(location: 0, length: 5)
      let partlyBold = NSRange(location: 0, length: 8)
      let caret = NSRange(location: 2, length: 0)
      #expect(Rich.activeTraits(in: s, selection: boldWord, typingAttributes: typing) == [.bold])
      // A selection only partly bold is not "on".
      #expect(Rich.activeTraits(in: s, selection: partlyBold, typingAttributes: typing).isEmpty)
      // A caret reports the typing style, not the text under it.
      var typingUnderlined = typing
      typingUnderlined[.underlineStyle] = NSUnderlineStyle.single.rawValue
      #expect(
        Rich.activeTraits(in: s, selection: caret, typingAttributes: typingUnderlined)
          == [.underline])
    }

    // MARK: Size cap (T-EDIT17)

    @Test func rtfAboveTheCapOpensAsPlainTextWithTheLossyWarning() {
      let rtf = Data("{\\rtf1 \\b bold\\b0}".utf8)
      let loaded = Rich.load(rtf: rtf, plainText: "bold", maxRTFBytes: rtf.count - 1)
      #expect(loaded.isLossy)
      #expect(loaded.attributed.string == "bold")
      #expect(!Rich.hasFormatting(loaded.attributed))
    }

    @Test func rtfAtTheCapIsStillParsed() {
      let rtf = Data("{\\rtf1 \\b bold\\b0}".utf8)
      let loaded = Rich.load(rtf: rtf, plainText: "bold", maxRTFBytes: rtf.count)
      #expect(Rich.hasFormatting(loaded.attributed))
    }

    @Test func defaultCapIsFinite() {
      #expect(Rich.maxEditableRTFBytes > 0)
      #expect(Rich.maxEditableRTFBytes <= 16 * 1024 * 1024)
    }

    @Test func loadCanRunInADetachedTask() async {
      let rtf = Data("{\\rtf1 \\b bold\\b0}".utf8)
      let loaded = await Task.detached { Rich.load(rtf: rtf, plainText: "bold") }.value
      #expect(Rich.hasFormatting(loaded.attributed))
    }
  }
#endif
