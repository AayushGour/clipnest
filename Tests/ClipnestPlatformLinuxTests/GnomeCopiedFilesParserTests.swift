import Testing

@testable import ClipnestPlatformLinux

@Suite("GnomeCopiedFilesParser")
struct GnomeCopiedFilesParserTests {
  @Test("Parses a single-file copy")
  func parsesSingleFile() {
    let result = GnomeCopiedFilesParser.parse("copy\nfile:///home/user/photo.png")
    #expect(result?.operation == "copy")
    #expect(result?.fileURIs == ["file:///home/user/photo.png"])
  }

  @Test("Parses a multi-file copy, per this task's exact example format")
  func parsesMultiFile() {
    let result = GnomeCopiedFilesParser.parse("copy\nfile:///a\nfile:///b")
    #expect(result?.operation == "copy")
    #expect(result?.fileURIs == ["file:///a", "file:///b"])
  }

  @Test("Parses a cut operation")
  func parsesCutOperation() {
    let result = GnomeCopiedFilesParser.parse("cut\nfile:///a")
    #expect(result?.operation == "cut")
  }

  @Test("Ignores blank lines within the URI list")
  func ignoresBlankLines() {
    let result = GnomeCopiedFilesParser.parse("copy\nfile:///a\n\nfile:///b\n")
    #expect(result?.fileURIs == ["file:///a", "file:///b"])
  }

  @Test("An operation line with no URIs parses to an empty (not nil) file list")
  func operationOnlyIsNotNil() {
    let result = GnomeCopiedFilesParser.parse("copy")
    #expect(result?.operation == "copy")
    #expect(result?.fileURIs == [])
  }

  @Test("Empty input returns nil")
  func emptyInputReturnsNil() {
    #expect(GnomeCopiedFilesParser.parse("") == nil)
  }
}
