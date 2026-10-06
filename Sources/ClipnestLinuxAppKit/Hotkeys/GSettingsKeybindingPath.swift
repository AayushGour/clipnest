import Foundation

/// Builds the GSettings object path for one of this app's custom
/// keybindings — pure string logic, unit-tested directly (this task's
/// "GSettings keybinding path building" mandated coverage).
///
/// **The one rule that matters here:** the path segment must be a NAMED
/// identifier (e.g. `clipnest-toggle`), never `customN` (`custom0`,
/// `custom1`, ...). GNOME Settings' own "Keyboard Shortcuts" UI allocates
/// `customN` slots sequentially and has no idea Clipnest also writes under
/// the same schema tree — if this app claimed `custom0` and the user later
/// added their own shortcut through Settings, GNOME Settings would also
/// try to allocate `custom0`, and one of the two bindings silently
/// overwrites the other's `name`/`command`/`binding` keys. A named segment
/// can never collide with GNOME Settings' own numeric allocation.
public enum GSettingsKeybindingPath {
  /// Matches exactly what GNOME Settings itself allocates
  /// (`customN` for a non-negative integer `N`, no leading zeros required
  /// by the UI) — used defensively by `path(forSegment:)` to refuse to
  /// build a colliding path even if a caller passes one by mistake.
  private static let reservedSlotPattern = "^custom[0-9]+$"

  public enum PathError: Error, Equatable {
    /// `segment` looks like a GNOME-Settings-allocated slot name
    /// (`customN`) — see this type's doc comment.
    case reservedSlotName(String)
    case emptySegment
  }

  /// - Parameter segment: a stable, named identifier for this specific
  ///   binding (e.g. `"clipnest-toggle"`, `"clipnest-expand-snippet"`) —
  ///   never derived from a counter or from user input.
  public static func path(forSegment segment: String) throws -> String {
    guard !segment.isEmpty else { throw PathError.emptySegment }
    guard segment.range(of: reservedSlotPattern, options: .regularExpression) == nil else {
      throw PathError.reservedSlotName(segment)
    }
    return "\(MediaKeysSchema.basePath)\(segment)/"
  }
}
