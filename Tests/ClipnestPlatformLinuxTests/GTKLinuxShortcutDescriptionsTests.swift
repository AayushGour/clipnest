// GTKLinuxShortcutDescriptionsTests.swift
//
// P7-D (Linux port, GTK4 view layer). See GTKKeyEventMappingTests.swift's
// top doc comment for the `ClipnestPlatformLinuxTests` -> `ClipnestGTK`
// manifest-dependency note that applies to every `GTK*Tests.swift` file.
import Testing

@testable import ClipnestGTK

@Suite("LinuxShortcutDescriptions")
struct GTKLinuxShortcutDescriptionsTests {
  @Test("Every entry has a non-empty combo and description")
  func everyEntryIsWellFormed() {
    #expect(!LinuxShortcutDescriptions.all.isEmpty)
    for entry in LinuxShortcutDescriptions.all {
      #expect(!entry.combo.isEmpty)
      #expect(!entry.description.isEmpty)
    }
  }

  @Test("Every combo is unique — no duplicated shortcut entries")
  func combosAreUnique() {
    let combos = LinuxShortcutDescriptions.all.map(\.combo)
    #expect(Set(combos).count == combos.count)
  }

  // T-BB6 regression: this list used to advertise "Ctrl+Delete" while the
  // picker footer (`ShortcutHints.swift`) advertised bare "Delete" for the
  // same action — a black-box-found contradiction between two in-app
  // surfaces. Pins the reconciled wording: the canonical chord matches the
  // footer's, and the description states the exception (Delete sometimes
  // edits the search box instead of the list) rather than only the modifier.
  //
  // T-KBPARITY3: the wording used to name the exact old condition
  // ("search box is empty"), which stopped being accurate once
  // `shouldPropagateToSearchEntry` started deciding on caret/selection state
  // instead — pinning the exact condition here would have made this test
  // (not just the string) go stale again at the next refinement. Pins the
  // now-condition-agnostic phrasing instead.
  @Test("Delete entry matches the footer's canonical chord and states the exception")
  func deleteEntryIsAccurate() {
    let delete = LinuxShortcutDescriptions.all.first {
      $0.description.contains("Delete the highlighted item")
    }
    #expect(delete?.combo == "Delete")
    #expect(delete?.description.contains("edit the search box") == true)
    #expect(delete?.description.contains("Ctrl+Delete") == true)
  }

  // Keyboard-parity pass (routed follow-up): the four newly-bound chords
  // (`KeyEventMapping.swift`) must be listed here with the exact same combo
  // wording `ShortcutHints.swift`'s Linux `platformDefault` advertises in the
  // footer — the same T-BB6 "two surfaces must agree" guard as the Delete
  // test above, extended to every new entry.
  @Test("Save/new/replace/settings entries exist with the footer's exact combo wording")
  func newEntriesMatchFooterWording() {
    let combos = Set(LinuxShortcutDescriptions.all.map(\.combo))
    #expect(combos.contains("Ctrl+S"))
    #expect(combos.contains("Ctrl+N"))
    #expect(combos.contains("Ctrl+Shift+E"))
    #expect(combos.contains("Ctrl+,"))
  }
}
