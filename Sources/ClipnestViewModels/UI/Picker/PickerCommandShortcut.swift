// PickerCommandShortcut.swift
//
// T-AUD-KBD: the macOS picker's newer ⌘-chords as a pure table
// (character + modifier booleans -> command), so the mapping is unit-testable
// without constructing a SwiftUI `KeyPress` (which has no public initializer).
// `PickerView.handle(_:)` translates `KeyPress` into these inputs and
// dispatches the result. Linux's equivalent table is `KeyEventMapping`.
//
// Chosen chords (none collides with ⌘F/P/S/N/1-3/,/⌫ or ⌥Return, and ⌘E is
// distinct from the GLOBAL snippet-expansion hotkey ⌥⌘E, which is handled by
// the system and additionally excluded here by rejecting ⌥):
//   ⌘]  next type filter     ⌘[  previous type filter
//   ⌘E  edit highlighted snippet (Snippets tab)
//   ⌘Y  toggle preview of the highlighted row (Quick Look's mnemonic; Space
//       is unusable because it types into the always-focused search field)
public enum PickerCommandShortcut: Equatable, Sendable {
  case nextFilter
  case previousFilter
  case editSnippet
  case togglePreview

  /// The command for ⌘+`character` pressed with exactly the given extra
  /// modifiers, or `nil`. Any of ⌥/⌃/⇧ held disqualifies the chord.
  public static func command(
    character: Character, command: Bool, option: Bool, control: Bool, shift: Bool
  ) -> PickerCommandShortcut? {
    guard command, !option, !control, !shift else { return nil }
    switch character {
    case "]": return .nextFilter
    case "[": return .previousFilter
    case "e", "E": return .editSnippet
    case "y", "Y": return .togglePreview
    default: return nil
    }
  }
}
