// UpdateCommandTests.swift — tag validation + pinned command construction.

import Testing

@testable import ClipnestViewModels

@Suite("UpdateCommand")
struct UpdateCommandTests {

  @Test("accepts vX.Y.Z and bare X.Y.Z, normalising to a v-prefixed tag")
  func acceptsValid() {
    #expect(UpdateCommand.validatedTag("v1.4.1") == "v1.4.1")
    #expect(UpdateCommand.validatedTag("1.4.1") == "v1.4.1")
    #expect(UpdateCommand.validatedTag("v10.0.123") == "v10.0.123")
  }

  @Test("rejects anything that is not strictly vDIGITS.DIGITS.DIGITS")
  func rejectsInvalid() {
    let bad: [String?] = [
      nil, "", "v", "v1", "v1.2", "v1.2.3.4", "v1..3", "v1.2.", "vv1.2.3", "v1.2.3-rc1",
      "v1.2.3\n", " v1.2.3", "v1.2.3 ", "v1.2.3;rm -rf ~", "v1.2.3$(id)", "v1.2.3`id`",
      "v1.2.3|bash", "v1.2.3&&id", "v١.٢.٣", "main", "../v1.2.3", "v1.2.x",
    ]
    for candidate in bad {
      let label = "should reject \(String(describing: candidate))"
      #expect(UpdateCommand.validatedTag(candidate) == nil, Comment(rawValue: label))
      #expect(UpdateCommand.command(forTag: candidate) == nil)
      #expect(UpdateCommand.scriptURL(forTag: candidate) == nil)
    }
  }

  @Test("script URL is pinned to the tag, never main")
  func urlPinned() {
    #expect(
      UpdateCommand.scriptURL(forTag: "v1.4.1")
        == "https://raw.githubusercontent.com/AayushGour/clipnest/v1.4.1/scripts/update.sh")
    #expect(!(UpdateCommand.command(forTag: "1.4.1") ?? "").contains("/main/"))
  }

  @Test("command is hardened curl piped to bash with the version env var")
  func commandShape() {
    #expect(
      UpdateCommand.command(forTag: "1.4.1")
        == "curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "
        + "https://raw.githubusercontent.com/AayushGour/clipnest/v1.4.1/scripts/update.sh "
        + "| CLIPNEST_VERSION=v1.4.1 bash")
  }
}
