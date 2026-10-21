import Foundation

/// Why a snippet-expansion attempt (`SnippetExpander.expand()`) did NOT replace
/// anything. Replaces the old silent beep: the composition root turns each
/// case into a user-visible message (copy lives in `ClipnestViewModels`'s
/// `SnippetExpansionCopy`, so wording exists once for both platforms).
public enum SnippetExpansionFailure: Sendable, Equatable {
  /// Nothing was selected, so there was no tag to look up.
  case noSelection
  /// Text was selected but no snippet uses it as its tag.
  case noMatch
  /// macOS Accessibility (the required permission) is not granted.
  case permissionMissing
  /// A selection matched a snippet but could not be replaced in the target
  /// app (terminal, unconfirmed clipboard write/copy).
  case replaceFailed

  /// Maps a clipboard-tier outcome to the failure to report, or `nil` when
  /// nothing should be reported: `.replaced` succeeded, and
  /// `.committedUnconfirmed` is an IBus commit that was delivered but cannot
  /// be acknowledged (it must not be reported as a failure; it used to beep).
  public init?(_ result: SelectionReplaceResult) {
    switch result {
    case .replaced, .committedUnconfirmed: return nil
    case .noSelection: self = .noSelection
    case .noMatch: self = .noMatch
    case .writeUnconfirmed, .copyUnconfirmed, .declinedTerminalTarget: self = .replaceFailed
    }
  }
}
