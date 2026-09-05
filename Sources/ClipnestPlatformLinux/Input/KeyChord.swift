import Foundation

/// A single `Character` — never arbitrary text, this whole stack only ever
/// posts short, fixed chords like Ctrl+V / Ctrl+Shift+V, mirroring the
/// bounded scope of `EventSynthesizing.synthesizeCommandV` — held down
/// together with a set of modifiers.
public struct KeyChord: Sendable, Equatable {
  public var modifiers: ModifierMask
  public var character: Character

  public init(modifiers: ModifierMask, character: Character) {
    self.modifiers = modifiers
    self.character = character
  }
}
