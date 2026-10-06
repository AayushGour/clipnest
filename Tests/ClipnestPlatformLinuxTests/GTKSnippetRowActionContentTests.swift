// GTKSnippetRowActionContentTests.swift
//
// Linux parity pass (routed follow-up, 2026-09-06). Exercises
// `SnippetRowActions.buttons()`/`.contextMenu()`
// (`Sources/ClipnestGTK/Window/SnippetRowActionContent.swift`) — pure,
// ungated logic (unlike `ItemRowActions`, every snippet supports both
// actions unconditionally), matching macOS `SnippetRow.swift` exactly.
import Testing

@testable import ClipnestGTK

@Suite("SnippetRowActions")
struct GTKSnippetRowActionContentTests {
  @Test("buttons() is exactly Edit, Delete — in that order")
  func buttonsAreEditThenDelete() {
    let entries = SnippetRowActions.buttons()
    #expect(entries.map(\.action) == [.edit, .delete])
    #expect(entries.map(\.label) == ["Edit", "Delete"])
  }

  @Test("contextMenu() is identical to buttons() — SnippetRow offers the same two actions in both")
  func contextMenuMatchesButtons() {
    #expect(SnippetRowActions.contextMenu() == SnippetRowActions.buttons())
  }

  @Test("Delete is the only destructive entry")
  func onlyDeleteIsDestructive() {
    for entry in SnippetRowActions.buttons() {
      #expect(entry.isDestructive == (entry.action == .delete))
    }
  }
}
