import Testing

@testable import ClipnestPlatformLinux

@Suite("UriListParser")
struct UriListParserTests {
  @Test("Parses CRLF-separated URIs per RFC 2483")
  func parsesCRLFSeparatedURIs() {
    let uris = UriListParser.parse("file:///a\r\nfile:///b\r\n")
    #expect(uris == ["file:///a", "file:///b"])
  }

  @Test("Ignores comment lines starting with #")
  func ignoresCommentLines() {
    let uris = UriListParser.parse("# a comment\r\nfile:///a\r\n# another comment\r\nfile:///b\r\n")
    #expect(uris == ["file:///a", "file:///b"])
  }

  @Test("Ignores blank lines")
  func ignoresBlankLines() {
    let uris = UriListParser.parse("file:///a\r\n\r\nfile:///b\r\n")
    #expect(uris == ["file:///a", "file:///b"])
  }

  @Test("Tolerant of a bare LF line ending, not just CRLF")
  func tolerantOfBareLF() {
    let uris = UriListParser.parse("file:///a\nfile:///b\n")
    #expect(uris == ["file:///a", "file:///b"])
  }

  @Test("Empty input yields an empty list")
  func emptyInputYieldsEmptyList() {
    #expect(UriListParser.parse("") == [])
  }
}
