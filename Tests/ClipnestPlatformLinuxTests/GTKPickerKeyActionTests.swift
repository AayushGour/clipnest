// GTKPickerKeyActionTests.swift
//
// P7-D (Linux port, GTK4 view layer). See GTKKeyEventMappingTests.swift's
// top doc comment for the `ClipnestPlatformLinuxTests` -> `ClipnestGTK`
// manifest-dependency note that applies to every `GTK*Tests.swift` file.
//
// Keyboard-parity pass (routed follow-up): exercises `PickerKeyAction
// .isTextEditingKeyWhenTypingInSearch` directly — previously untested at the
// unit level (only reachable indirectly through `PickerWindow+Keyboard
// .swift`'s `handleKeyPressed`, which needs a real GTK window). Pure
// `Equatable`/no-GTK-dependency logic, same shape as `KeyEventMapping
// .action(keyval:state:)`'s own coverage.
import Testing

@testable import ClipnestGTK

@Suite("PickerKeyAction.isTextEditingKeyWhenTypingInSearch")
struct GTKPickerKeyActionTests {
  @Test("Only .delete is a text-editing key the search entry can own")
  func onlyDeleteQualifies() {
    #expect(PickerKeyAction.delete.isTextEditingKeyWhenTypingInSearch)
  }

  @Test(
    "Every other action — including the four keyboard-parity additions — is NOT a text-editing key, so it always dispatches even while typing"
  )
  func everyOtherActionDoesNotQualify() {
    let nonTextEditingActions: [PickerKeyAction] = [
      .moveUp,
      .moveDown,
      .commit(plainText: false),
      .commit(plainText: true),
      .dismiss,
      .focusSearch,
      .togglePin,
      .switchTab(.one),
      .switchTab(.two),
      .switchTab(.three),
      .saveAsSnippet,
      .newSnippet,
      .replaceSnippet,
      .openSettings,
    ]
    for action in nonTextEditingActions {
      #expect(!action.isTextEditingKeyWhenTypingInSearch, "\(action) must not qualify")
    }
  }
}
