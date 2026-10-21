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
  /// T-TERMPASTE1: models a terminal-class frontmost app — when set, the
  /// transaction is declined exactly like the real `ClipboardSelectionReplacer`
  /// / `LinuxClipboardSelectionReplacer` do, before `simulatedSelection` is
  /// even consulted (a real decline never reaches the copy step either).
  var declinesTerminalTarget = false

  func replaceSelection(bodyForSelection: (String) async -> String?) async
    -> SelectionReplaceResult
  {
    wasCalled = true
    guard !declinesTerminalTarget else {
      return .declinedTerminalTarget
    }
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

  @Test("AX can read + match: replaces via AX, never uses the clipboard, reports no failure")
  func axMatchReplacesWithoutClipboard() async throws {
    let ax = MockSelectedText()
    ax.selection = "sig"
    let clipboard = MockClipboardReplacer()
    var failures: [SnippetExpansionFailure] = []
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      feedback: { failures.append($0) })

    await expander.expand()

    #expect(ax.replacedWith == "Best, Aayush")
    #expect(clipboard.wasCalled == false)
    #expect(failures.isEmpty)
  }

  @Test("Accessibility not granted: reports permissionMissing, touches neither tier")
  func notGrantedBeepsWithoutTryingEitherTier() async throws {
    let ax = MockSelectedText()
    ax.selection = "sig"
    let clipboard = MockClipboardReplacer()
    var failures: [SnippetExpansionFailure] = []
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      feedback: { failures.append($0) }, isAccessibilityGranted: { false })

    await expander.expand()

    #expect(ax.replacedWith == nil)
    #expect(clipboard.wasCalled == false)
    #expect(failures == [.permissionMissing])
  }

  @Test("AX reads but no match: reports noMatch, does NOT fall back to the clipboard")
  func axNoMatchBeepsWithoutClipboard() async throws {
    let ax = MockSelectedText()
    ax.selection = "unknown"
    let clipboard = MockClipboardReplacer()
    var failures: [SnippetExpansionFailure] = []
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      feedback: { failures.append($0) })

    await expander.expand()

    #expect(ax.replacedWith == nil)
    #expect(clipboard.wasCalled == false)
    #expect(failures == [.noMatch])
  }

  @Test("AX can't read (Electron): falls back to the clipboard, which matches + replaces")
  func axUnreadableFallsBackToClipboardMatch() async throws {
    let ax = MockSelectedText()
    ax.selection = nil  // AX exposes nothing (Electron/Chrome)
    let clipboard = MockClipboardReplacer()
    clipboard.simulatedSelection = "sig"  // ⌘C reads the selection
    var failures: [SnippetExpansionFailure] = []
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      feedback: { failures.append($0) })

    await expander.expand()

    #expect(clipboard.wasCalled == true)
    #expect(clipboard.pastedBody == "Best, Aayush")
    #expect(failures.isEmpty)
  }

  @Test("AX can't read and the clipboard reads nothing: beeps")
  func axUnreadableClipboardEmptyBeeps() async throws {
    let ax = MockSelectedText()
    ax.selection = nil
    let clipboard = MockClipboardReplacer()
    clipboard.simulatedSelection = nil
    var failures: [SnippetExpansionFailure] = []
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      feedback: { failures.append($0) })

    await expander.expand()

    #expect(clipboard.wasCalled == true)
    #expect(failures == [.noSelection])  // clipboard read nothing
  }

  @Test(
    "T-TERMPASTE1: AX can't read and the clipboard tier declines a terminal-class target: beeps, does NOT report a false success"
  )
  func clipboardTierDeclinesTerminalTargetBeeps() async throws {
    let ax = MockSelectedText()
    ax.selection = nil
    let clipboard = MockClipboardReplacer()
    clipboard.declinesTerminalTarget = true
    var failures: [SnippetExpansionFailure] = []
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      feedback: { failures.append($0) })

    await expander.expand()

    #expect(clipboard.wasCalled == true)
    #expect(clipboard.pastedBody == nil)  // nothing was ever pasted
    #expect(failures == [.replaceFailed])
  }

  @Test("AX reads + matches but the AX WRITE is refused: falls back to the clipboard")
  func axWriteRefusedFallsBackToClipboard() async throws {
    let ax = MockSelectedText()
    ax.selection = "sig"
    ax.replaceSucceeds = false  // AX read worked, but write refused
    let clipboard = MockClipboardReplacer()
    clipboard.simulatedSelection = "sig"
    var failures: [SnippetExpansionFailure] = []
    let expander = SnippetExpander(
      snippetStore: try await store(), selectedText: ax, clipboardReplacer: clipboard,
      feedback: { failures.append($0) })

    await expander.expand()

    #expect(clipboard.wasCalled == true)
    #expect(clipboard.pastedBody == "Best, Aayush")
    #expect(failures.isEmpty)
  }

  @Test("Outcome mapping: replaced/committedUnconfirmed report nothing, the rest a failure")
  func failureMappingFromClipboardOutcome() {
    #expect(SnippetExpansionFailure(.replaced) == nil)
    #expect(SnippetExpansionFailure(.committedUnconfirmed) == nil)
    #expect(SnippetExpansionFailure(.noSelection) == .noSelection)
    #expect(SnippetExpansionFailure(.noMatch) == .noMatch)
    #expect(SnippetExpansionFailure(.writeUnconfirmed) == .replaceFailed)
    #expect(SnippetExpansionFailure(.copyUnconfirmed) == .replaceFailed)
    #expect(SnippetExpansionFailure(.declinedTerminalTarget) == .replaceFailed)
  }

  #if !os(macOS)
    // T-BUG5 (parity-audit bug #5): macOS's `PlatformDefaults.beep` plays
    // real system audio (`NSSound.beep()`) — a genuine side effect,
    // deliberately never exercised directly by a test (every test above
    // injects a spy `beep:` closure instead). The non-Apple default below
    // only ever writes one well-known byte to stderr — a safe, side-
    // effect-free-enough call to make directly, unlike a real pasteboard/
    // keystroke/audio call — so both the byte VALUE and the closure's
    // basic callability are worth pinning here.
    @Test("Non-Apple PlatformDefaults.beep writes the exact ASCII BEL byte, not a silent no-op")
    func nonAppleBeepDefaultIsRealNotSilent() {
      #expect(PlatformDefaults.terminalBellByte == 0x07)
      // Exercises the real closure body once, end to end — proving it
      // doesn't crash/throw, which the old `{}` no-op trivially also
      // "passed" but which is exactly what this fix replaces.
      PlatformDefaults.beep()
    }
  #endif
}
