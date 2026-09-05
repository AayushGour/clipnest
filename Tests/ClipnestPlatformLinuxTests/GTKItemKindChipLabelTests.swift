// GTKItemKindChipLabelTests.swift
//
// P7-D (Linux port, GTK4 view layer). See GTKKeyEventMappingTests.swift's
// top doc comment for the `ClipnestPlatformLinuxTests` -> `ClipnestGTK`
// manifest-dependency note that applies to every `GTK*Tests.swift` file.
import ClipnestCore
import Testing

@testable import ClipnestGTK

@Suite("ItemKindChipLabel")
struct GTKItemKindChipLabelTests {
  @Test("Every ItemKind case has a distinct, non-empty chip label")
  func everyKindHasADistinctLabel() {
    let labels = ItemKind.allCases.map { ItemKindChipLabel.label(for: $0) }
    #expect(labels.allSatisfy { !$0.isEmpty })
    #expect(Set(labels).count == labels.count)
  }

  @Test("Specific label wording, so a future edit that changes it is deliberate")
  func specificWording() {
    #expect(ItemKindChipLabel.label(for: .text) == "Text")
    #expect(ItemKindChipLabel.label(for: .richText) == "Rich Text")
    #expect(ItemKindChipLabel.label(for: .link) == "Link")
    #expect(ItemKindChipLabel.label(for: .image) == "Image")
    #expect(ItemKindChipLabel.label(for: .file) == "File")
  }
}
