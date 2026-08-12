import Testing

@testable import ClipnestCore

/// Fake AX `SelectedTextAccessing` — records writes instead of touching real
/// Accessibility (per coding-standards.md's testing rules).
private final class MockSelectedText: SelectedTextAccessing, @unchecked Sendable {
  var selection: String?
  private(set) var replacedWith: String?
  var replaceSucceeds = true

  func readSelectedText() -> String? { selection }

  @discardableResult
  func replaceSelectedText(with text: String) -> Bool {
    replacedWith = text
    return replaceSucceeds
  }
}

/// Fake clipboard fallback — simulates the ⌘C read via `simulatedSelection`
/// and runs the real `bodyForSelection` lookup, so tests exercise the
/// expander's fallback logic without synthesizing keystrokes or touching the
/// real pasteboard.
@MainActor
private final class MockClipboardReplacer: SelectionReplacing {
  var simulatedSelection: String?
  private(set) var wasCalled = false
  private(set) var pastedBody: String?

  func replaceSelection(bodyForSelection: (String) async -> String?) async
    -> SelectionReplaceResult
  {
    wasCalled = true
    guard let selection = simulatedSelection,
      !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return .noSelection
    }
    guard let body = await bodyForSelection(selection) else {
      return .noMatch
    }
    pastedBody = body
    return .replaced
  }
}

@MainActor
@Suite("SnippetExpander")
struct SnippetExpanderTests {
  private func store() async throws -> InMemorySnippetStore {
    let store = InMemorySnippetStore()
    _ = try await store.create(Snippet(title: "Sig", body: "Best, Aayush", keyword: "sig"))
    return store
  }

  @Test("AX can read + match: replaces via AX, never uses the clipboard, never beeps")
  func axMatchReplacesWithoutClipboard() async throws {
    let ax = MockSelectedText()
    ax.selection = "sig"
    let clipboard = MockClipboardReplacer()
    var beeped = false
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      beep: { beeped = true })

    await expander.expand()

    #expect(ax.replacedWith == "Best, Aayush")
    #expect(clipboard.wasCalled == false)
    #expect(beeped == false)
  }

  @Test("AX reads but no match: beeps, does NOT fall back to the clipboard")
  func axNoMatchBeepsWithoutClipboard() async throws {
    let ax = MockSelectedText()
    ax.selection = "unknown"
    let clipboard = MockClipboardReplacer()
    var beeped = false
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      beep: { beeped = true })

    await expander.expand()

    #expect(ax.replacedWith == nil)
    #expect(clipboard.wasCalled == false)
    #expect(beeped == true)
  }

  @Test("AX can't read (Electron): falls back to the clipboard, which matches + replaces")
  func axUnreadableFallsBackToClipboardMatch() async throws {
    let ax = MockSelectedText()
    ax.selection = nil  // AX exposes nothing (Electron/Chrome)
    let clipboard = MockClipboardReplacer()
    clipboard.simulatedSelection = "sig"  // ⌘C reads the selection
    var beeped = false
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      beep: { beeped = true })

    await expander.expand()

    #expect(clipboard.wasCalled == true)
    #expect(clipboard.pastedBody == "Best, Aayush")
    #expect(beeped == false)
  }

  @Test("AX can't read and the clipboard reads nothing: beeps")
  func axUnreadableClipboardEmptyBeeps() async throws {
    let ax = MockSelectedText()
    ax.selection = nil
    let clipboard = MockClipboardReplacer()
    clipboard.simulatedSelection = nil
    var beeped = false
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      beep: { beeped = true })

    await expander.expand()

    #expect(clipboard.wasCalled == true)
    #expect(beeped == true)  // clipboard read nothing → .noSelection → beep
  }

  @Test("AX reads + matches but the AX WRITE is refused: falls back to the clipboard")
  func axWriteRefusedFallsBackToClipboard() async throws {
    let ax = MockSelectedText()
    ax.selection = "sig"
    ax.replaceSucceeds = false  // AX read worked, but write refused
    let clipboard = MockClipboardReplacer()
    clipboard.simulatedSelection = "sig"
    var beeped = false
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      beep: { beeped = true })

    await expander.expand()

    #expect(clipboard.wasCalled == true)
    #expect(clipboard.pastedBody == "Best, Aayush")
    #expect(beeped == false)
  }
}
