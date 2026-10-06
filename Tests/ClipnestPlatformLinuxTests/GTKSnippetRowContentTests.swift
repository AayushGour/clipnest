// GTKSnippetRowContentTests.swift
//
// P7-D (Linux port, GTK4 view layer). See GTKKeyEventMappingTests.swift's
// top doc comment for the `ClipnestPlatformLinuxTests` -> `ClipnestGTK`
// manifest-dependency note that applies to every `GTK*Tests.swift` file.
import ClipnestCore
import Testing

@testable import ClipnestGTK

@Suite("SnippetRowContent")
struct GTKSnippetRowContentTests {
  @Test("markupTitle/markupBody each highlight the search text independently")
  func highlightsBothFieldsIndependently() {
    let snippet = Snippet(title: "Greeting", body: "hello world", keyword: nil)

    let content = SnippetRowContent(snippet: snippet, searchText: "world")
    #expect(!content.markupTitle.contains("<span"))
    #expect(content.markupBody.contains("<span"))
  }

  @Test("keywordLabel mirrors the snippet's keyword, including nil")
  func keywordLabelMirrorsSnippet() {
    let withKeyword = Snippet(title: "t", body: "b", keyword: "sig")
    #expect(SnippetRowContent(snippet: withKeyword, searchText: "").keywordLabel == "sig")

    let withoutKeyword = Snippet(title: "t", body: "b", keyword: nil)
    #expect(SnippetRowContent(snippet: withoutKeyword, searchText: "").keywordLabel == nil)
  }
}
