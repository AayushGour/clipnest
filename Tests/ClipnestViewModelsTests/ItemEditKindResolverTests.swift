import ClipnestCore
import Testing

@testable import ClipnestViewModels

@Suite("ItemEditKindResolver")
struct ItemEditKindResolverTests {
  @Test func plainTextWithoutFormattingStaysText() {
    #expect(
      ItemEditKindResolver.resolve(
        originalKind: .text, plainText: "hello",
        hasFormatting: false)
        == .text)
  }

  @Test func anyFormattingMakesRichText() {
    #expect(
      ItemEditKindResolver.resolve(
        originalKind: .text, plainText: "hello",
        hasFormatting: true)
        == .richText)
  }

  @Test func linkEditedToNonURLBecomesText() {
    #expect(
      ItemEditKindResolver.resolve(
        originalKind: .link, plainText: "not a url",
        hasFormatting: false)
        == .text)
  }

  @Test func linkStaysLinkWhileSingleURLUnformatted() {
    #expect(
      ItemEditKindResolver.resolve(
        originalKind: .link, plainText: "https://a.b",
        hasFormatting: false)
        == .link)
  }

  @Test func formattedLinkBecomesRichText() {
    #expect(
      ItemEditKindResolver.resolve(
        originalKind: .link, plainText: "https://a.b",
        hasFormatting: true)
        == .richText)
  }

  @Test func richTextWithAllFormattingRemovedStaysRichText() {
    #expect(
      ItemEditKindResolver.resolve(
        originalKind: .richText, plainText: "x",
        hasFormatting: false)
        == .richText)
  }

  @Test func textEditedIntoLoneURLBecomesLinkLikeCapture() {
    #expect(
      ItemEditKindResolver.resolve(
        originalKind: .text, plainText: "  https://a.b\n", hasFormatting: false) == .link)
  }

  @Test func whitespaceOnlyCannotSave() {
    #expect(!ItemEditValidation.canSave(plainText: ""))
    #expect(!ItemEditValidation.canSave(plainText: "  \n\t"))
    #expect(ItemEditValidation.canSave(plainText: "a"))
  }
}
