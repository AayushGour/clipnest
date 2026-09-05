import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("GSettingsKeybindingPath")
struct AppGSettingsKeybindingPathTests {
  @Test("builds a path under the custom-keybindings base for a named segment")
  func buildsPathForNamedSegment() throws {
    let path = try GSettingsKeybindingPath.path(forSegment: "clipnest-toggle")
    #expect(
      path
        == "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/clipnest-toggle/")
  }

  @Test("rejects customN — the slot pattern GNOME Settings itself allocates")
  func rejectsReservedSlotNames() throws {
    #expect(throws: GSettingsKeybindingPath.PathError.reservedSlotName("custom0")) {
      try GSettingsKeybindingPath.path(forSegment: "custom0")
    }
    do {
      _ = try GSettingsKeybindingPath.path(forSegment: "custom42")
      Issue.record("expected .reservedSlotName to be thrown")
    } catch GSettingsKeybindingPath.PathError.reservedSlotName(let segment) {
      #expect(segment == "custom42")
    }
  }

  @Test("accepts a segment that merely CONTAINS 'custom' but isn't the exact reserved pattern")
  func acceptsNonExactCustomLookalikes() throws {
    let path = try GSettingsKeybindingPath.path(forSegment: "clipnest-custom-toggle")
    #expect(path.contains("clipnest-custom-toggle"))
  }

  @Test("rejects an empty segment")
  func rejectsEmptySegment() {
    #expect(throws: GSettingsKeybindingPath.PathError.emptySegment) {
      try GSettingsKeybindingPath.path(forSegment: "")
    }
  }
}
