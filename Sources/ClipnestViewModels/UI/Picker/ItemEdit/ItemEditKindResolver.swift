import ClipnestCore

/// Decides the `ItemKind` an item has after its text was edited.
public enum ItemEditKindResolver {
  /// - An item that was `.richText` stays `.richText`, even if every bit of
  ///   formatting was removed.
  /// - Otherwise any formatting makes it `.richText`.
  /// - Otherwise it is `.link` when the trimmed text is a single URL (the same
  ///   `LinkDetection` check capture uses, so capture and edit never
  ///   disagree), else `.text`.
  public static func resolve(
    originalKind: ItemKind, plainText: String, hasFormatting: Bool
  ) -> ItemKind {
    if originalKind == .richText || hasFormatting { return .richText }
    let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    return LinkDetection.isLink(trimmed) ? .link : .text
  }
}

public enum ItemEditValidation {
  /// An edit can be saved only if it has non-whitespace content.
  public static func canSave(plainText: String) -> Bool {
    !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
