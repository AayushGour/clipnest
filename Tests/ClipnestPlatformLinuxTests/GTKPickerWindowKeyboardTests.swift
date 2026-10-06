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
// T-KBPARITY3 (Linux/macOS key-handling parity pass): the original fix's
// third parameter was `searchText: String` (propagate whenever the box had
// ANY text) — a coarse approximation that got the empty-box case right but
// not "caret at the end of non-empty text," where macOS's `TextField`
// bubbles a no-op forward-delete to the picker but the old Linux check
// always forwarded to the entry instead (see `PickerWindow+Keyboard.swift`'s
// `handleKeyPressed` doc comment for the full investigation, including why a
// literal `GTK_PHASE_BUBBLE` controller — verified empirically, not assumed
// — can't replace this: `GtkText`'s Delete binding always reports itself as
// handled, even as a no-op, so a bubble-phase controller never sees Delete
// at all while the entry has focus). The parameter is now
// `searchEntryEditWouldHaveEffect: Bool` — true iff the entry has a
// selection or a character after the caret, i.e. iff `GtkText`'s own Delete
// binding would actually change its content.
//
// `PickerWindow.shouldPropagateToSearchEntry(action:focusIsInSearchEntry:
// searchEntryEditWouldHaveEffect:)` (same file) is the pure decision — three
// plain values in, one `Bool` out, no GTK/display dependency — so this suite
// exercises it directly, the same way `GTKKeyEventMappingTests.swift`
// exercises `KeyEventMapping.action(keyval:state:)`. It is `static`, so
// calling it needs no `PickerWindow` instance (and therefore no
// `gtk_init()`/display) at all. The live-GTK half of the decision
// (`searchEntryDeleteWouldHaveEffect(_:)`, reading real caret/selection
// state) is intentionally NOT unit-tested here for the same reason
// `gtkFocusIsWithin` isn't — it needs a real widget tree/display; it's
// covered instead by this task's runtime VNC proof (see
// `.claude/logs/senior-dev.md`).
import Testing

@testable import ClipnestGTK

@Suite("PickerWindow.shouldPropagateToSearchEntry")
struct GTKPickerWindowKeyboardTests {
  @Test(
    "Delete + focus in search + a character after the caret (mid-text): propagate to the entry, don't delete the item"
  )
  func deleteMidTextPropagates() {
    #expect(
      PickerWindow.shouldPropagateToSearchEntry(
        action: .delete, focusIsInSearchEntry: true, searchEntryEditWouldHaveEffect: true))
  }

  @Test(
    "Delete + focus in search + caret at the END of non-empty text (nothing to forward-delete): the picker acts — the exact macOS-parity gap this task closes"
  )
  func deleteAtEndOfNonEmptyTextActsOnThePicker() {
    // Old behaviour (searchText.isEmpty-based) always propagated here
    // because the box had text, which let GTK ring its error bell and
    // swallow the keystroke instead of it ever reaching the picker — unlike
    // macOS, where a no-op forward-delete bubbles to `.onKeyPress` and
    // deletes the highlighted row. `searchEntryEditWouldHaveEffect: false`
    // is exactly this case: focused, but nothing for Delete to do.
    #expect(
      !PickerWindow.shouldPropagateToSearchEntry(
        action: .delete, focusIsInSearchEntry: true, searchEntryEditWouldHaveEffect: false))
  }

  @Test(
    "Delete + focus in search + EMPTY text: the picker acts (deletes the highlighted item) — the exact case a focus-only check gets wrong"
  )
  func deleteWithEmptySearchActsOnThePicker() {
    // `willShow()` focuses the search entry every time the picker opens, so
    // a focus-only version of this check would mean bare Delete never
    // reaches the list at all — a real regression a first attempt at the P0
    // fix introduced. An empty box is the degenerate case of "caret at the
    // end," so `searchEntryEditWouldHaveEffect: false` covers it too —
    // same outcome as the previous `searchText: ""` case, no regression.
    #expect(
      !PickerWindow.shouldPropagateToSearchEntry(
        action: .delete, focusIsInSearchEntry: true, searchEntryEditWouldHaveEffect: false))
  }

  @Test(
    "Delete + focus in search + an active SELECTION: propagate to the entry (it deletes the selection), matching macOS"
  )
  func deleteWithActiveSelectionPropagates() {
    #expect(
      PickerWindow.shouldPropagateToSearchEntry(
        action: .delete, focusIsInSearchEntry: true, searchEntryEditWouldHaveEffect: true))
  }

  @Test("Delete + focus NOT in search: the picker acts, regardless of whether an edit would happen")
  func deleteOutsideSearchActsOnThePickerRegardlessOfEditEffect() {
    #expect(
      !PickerWindow.shouldPropagateToSearchEntry(
        action: .delete, focusIsInSearchEntry: false, searchEntryEditWouldHaveEffect: true))
    #expect(
      !PickerWindow.shouldPropagateToSearchEntry(
        action: .delete, focusIsInSearchEntry: false, searchEntryEditWouldHaveEffect: false))
  }

  @Test(
    "A non-text-editing action (togglePin) never propagates, in every focus/edit-effect combination — the picker always acts on it",
    arguments: [true, false], [true, false])
  func nonTextEditingActionAlwaysActsOnThePicker(
    focusIsInSearchEntry: Bool, searchEntryEditWouldHaveEffect: Bool
  ) {
    #expect(
      !PickerWindow.shouldPropagateToSearchEntry(
        action: .togglePin, focusIsInSearchEntry: focusIsInSearchEntry,
        searchEntryEditWouldHaveEffect: searchEntryEditWouldHaveEffect))
  }

  // MARK: - Every other action, one exhaustive pass — arrows/Ctrl-chords
  // (including the four keyboard-parity additions) must ALWAYS act on the
  // picker too, even while typing a search with focus there, matching
  // macOS's Cmd-chords/arrow-key navigation both working while a SwiftUI
  // `TextField` has focus.

  @Test(
    "Every action other than delete never propagates, even with focus in an entry that would edit"
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
          action: action, focusIsInSearchEntry: true, searchEntryEditWouldHaveEffect: true),
        "\(action) must always act on the picker, never propagate")
    }
  }
}
