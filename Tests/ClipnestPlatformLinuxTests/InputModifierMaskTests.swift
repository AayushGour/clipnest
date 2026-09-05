import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("ModifierMask")
struct ModifierMaskTests {
  @Test("individual flags are distinct bits")
  func distinctBits() {
    let all: [ModifierMask] = [.control, .shift, .alt, .superKey]
    for (index, flag) in all.enumerated() {
      for (otherIndex, other) in all.enumerated() where otherIndex != index {
        #expect(!flag.contains(other))
      }
    }
  }

  @Test("combines via OptionSet union")
  func combines() {
    let combined: ModifierMask = [.control, .shift]
    #expect(combined.contains(.control))
    #expect(combined.contains(.shift))
    #expect(!combined.contains(.alt))
    #expect(!combined.isEmpty)
  }

  @Test("empty mask reports isEmpty")
  func empty() {
    let mask: ModifierMask = []
    #expect(mask.isEmpty)
  }
}
