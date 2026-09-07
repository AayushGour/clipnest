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
  // footer's, and the description states the search-box-empty condition
  // (the P0 data-loss fix landed in the same session) rather than only the
  // modifier.
  @Test("Delete entry matches the footer's canonical chord and states the search-box condition")
  func deleteEntryIsAccurate() {
    let delete = LinuxShortcutDescriptions.all.first {
      $0.description.contains("Delete the highlighted item")
    }
    #expect(delete?.combo == "Delete")
    #expect(delete?.description.contains("search box is empty") == true)
    #expect(delete?.description.contains("Ctrl+Delete") == true)
  }
}
