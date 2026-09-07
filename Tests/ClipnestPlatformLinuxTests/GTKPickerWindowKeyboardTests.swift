// GTKPickerWindowKeyboardTests.swift
//
// P7-D (Linux port, GTK4 view layer). See GTKKeyEventMappingTests.swift's
// top doc comment for the `ClipnestPlatformLinuxTests` -> `ClipnestGTK`
// manifest-dependency note that applies to every `GTK*Tests.swift` file.
//
// Regression-coverage pass (routed follow-up, an independent reviewer
// rejection): commit 8642aee fixed the P0 data-loss bug — typing in the
// picker's search field and pressing bare Delete permanently destroyed the
// highlighted clip item, no confirmation, no undo, reproduced as 4 rows -> 3
// on a clean build — but touched no test file at all; it shipped verified by
// exactly one manual run on Ubuntu. The decision that fix depends on used to
// live entirely inside `PickerWindow+Keyboard.swift`'s private
// `isTypingInSearchField` computed var, which read live GTK widget/focus
// state directly and so could not be unit-tested as written.
//
// `PickerWindow.shouldPropagateToSearchEntry(action:focusIsInSearchEntry:
// searchText:)` (same file) is the pure extraction of that exact decision —
// three plain values in, one `Bool` out, no GTK/display dependency — so this
// suite exercises it directly, the same way `GTKKeyEventMappingTests.swift`
// exercises `KeyEventMapping.action(keyval:state:)`. It is `static`, so
// calling it needs no `PickerWindow` instance (and therefore no
// `gtk_init()`/display) at all.
import Testing

@testable import ClipnestGTK

@Suite("PickerWindow.shouldPropagateToSearchEntry")
struct GTKPickerWindowKeyboardTests {
  @Test("Delete + focus in search + non-empty text: propagate to the entry, don't delete the item")
  func deleteWhileTypingPropagates() {
    #expect(
      PickerWindow.shouldPropagateToSearchEntry(
        action: .delete, focusIsInSearchEntry: true, searchText: "abc"))
  }

  @Test(
    "Delete + focus in search + EMPTY text: the picker acts (deletes the highlighted item) — the exact case a focus-only check gets wrong"
  )
  func deleteWithEmptySearchActsOnThePicker() {
    // `willShow()` focuses the search entry every time the picker opens, so
    // a focus-only version of this check would mean bare Delete never
    // reaches the list at all — a real regression a first attempt at the P0
    // fix introduced. Pinning `searchText: ""` here guards specifically
    // against that regression coming back.
    #expect(
      !PickerWindow.shouldPropagateToSearchEntry(
        action: .delete, focusIsInSearchEntry: true, searchText: ""))
  }

  @Test("Delete + focus NOT in search: the picker acts, regardless of the entry's text")
  func deleteOutsideSearchActsOnThePickerRegardlessOfText() {
    #expect(
      !PickerWindow.shouldPropagateToSearchEntry(
        action: .delete, focusIsInSearchEntry: false, searchText: "abc"))
    #expect(
      !PickerWindow.shouldPropagateToSearchEntry(
        action: .delete, focusIsInSearchEntry: false, searchText: ""))
  }

  @Test(
    "A non-text-editing action (togglePin) never propagates, in every focus/text combination — the picker always acts on it",
    arguments: [true, false], ["", "abc"])
  func nonTextEditingActionAlwaysActsOnThePicker(focusIsInSearchEntry: Bool, searchText: String) {
    #expect(
      !PickerWindow.shouldPropagateToSearchEntry(
        action: .togglePin, focusIsInSearchEntry: focusIsInSearchEntry, searchText: searchText))
  }

  // MARK: - Every other action, one exhaustive pass — arrows/Ctrl-chords
  // (including the four keyboard-parity additions) must ALWAYS act on the
  // picker too, even while typing a search with focus there, matching
  // macOS's Cmd-chords/arrow-key navigation both working while a SwiftUI
  // `TextField` has focus.

  @Test(
    "Every action other than delete never propagates, even with focus in a non-empty search field"
  )
  func everyOtherActionNeverPropagatesWhileTypingWithFocus() {
    let otherActions: [PickerKeyAction] = [
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
    for action in otherActions {
      #expect(
        !PickerWindow.shouldPropagateToSearchEntry(
          action: action, focusIsInSearchEntry: true, searchText: "abc"),
        "\(action) must always act on the picker, never propagate")
    }
  }
}
