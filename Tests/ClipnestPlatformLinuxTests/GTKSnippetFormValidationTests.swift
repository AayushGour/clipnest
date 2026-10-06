// GTKSnippetFormValidationTests.swift
//
// Linux parity pass (routed follow-up, 2026-09-06). Exercises
// `SnippetFormValidation.isSaveEnabled(tag:body:)`
// (`Sources/ClipnestGTK/Window/SnippetFormValidation.swift`) — pure logic,
// no GTK/display dependency. Pins the exact rule macOS's `SnippetFormView
// .isSaveDisabled` uses: both fields must be non-empty after trimming
// whitespace/newlines.
import Testing

@testable import ClipnestGTK

@Suite("SnippetFormValidation")
struct GTKSnippetFormValidationTests {
  @Test("Both fields non-empty enables Save")
  func bothNonEmptyEnables() {
    #expect(SnippetFormValidation.isSaveEnabled(tag: "sig", body: "hello"))
  }

  @Test("An empty tag disables Save even with a non-empty body")
  func emptyTagDisables() {
    #expect(!SnippetFormValidation.isSaveEnabled(tag: "", body: "hello"))
  }

  @Test("An empty body disables Save even with a non-empty tag")
  func emptyBodyDisables() {
    #expect(!SnippetFormValidation.isSaveEnabled(tag: "sig", body: ""))
  }

  @Test("Whitespace-only fields count as empty (trimmed before checking)")
  func whitespaceOnlyCountsAsEmpty() {
    #expect(!SnippetFormValidation.isSaveEnabled(tag: "   ", body: "hello"))
    #expect(!SnippetFormValidation.isSaveEnabled(tag: "sig", body: "\n\t "))
    #expect(!SnippetFormValidation.isSaveEnabled(tag: "  ", body: "  "))
  }

  @Test("Leading/trailing whitespace around otherwise-valid content still enables Save")
  func surroundingWhitespaceStillEnables() {
    #expect(SnippetFormValidation.isSaveEnabled(tag: "  sig  ", body: "  hello  "))
  }
}
