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
}
