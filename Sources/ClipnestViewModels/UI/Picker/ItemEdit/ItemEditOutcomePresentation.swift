/// What an editor popup does with an `ItemEditOutcome`. Pure, so the macOS
/// and Linux editors share one rule and it is unit-tested.
public struct ItemEditOutcomePresentation: Equatable, Sendable {
  /// Inline message to show, or nil when there is none.
  public let errorMessage: String?
  /// Whether the picker list must be refreshed. True for `.failed` too: a
  /// failure may follow a partially applied write; true for
  /// `.itemNoLongerExists` so the picker drops the ghost row.
  public let refreshList: Bool
  /// Whether the editor closes. Only a clean save closes it.
  public let closesEditor: Bool

  public init(outcome: ItemEditOutcome) {
    switch outcome {
    case .saved:
      errorMessage = nil
      refreshList = true
      closesEditor = true
    case .itemNoLongerExists:
      errorMessage = ItemEditStrings.itemGone
      refreshList = true  // drop the ghost row; the editor stays open
      closesEditor = false
    case .failed(let message):
      errorMessage = message
      refreshList = true
      closesEditor = false
    }
  }
}
