import Foundation

/// Pure MIME-priority resolution over a `TARGETS` reply's atom-name list —
/// no X11, no I/O, no payload bytes. `LinuxPasteboard` calls this once per
/// category to decide (a) whether that category is even offered, and (b)
/// which single MIME type within it should actually be requested, per
/// `LinuxClipboardConstants`'s priority lists.
///
/// Comparison is exact and case-sensitive, matching X11 atom-name and MIME
/// type convention (`text/html` and `TEXT/HTML` are not the same atom).
public enum MimeRepresentationSelector {
  /// The highest-priority MIME type within `category` that appears in
  /// `availableMimeTypes`, or `nil` if none of that category's priority
  /// list is offered.
  ///
  /// Deliberately independent per category — unlike a single
  /// "pick the one overall best representation" call, this lets a caller
  /// ask "is there ALSO a plain-text fallback" even when a higher-priority
  /// category (e.g. rich text) is what ultimately wins the capture, exactly
  /// the shape `PasteboardReader.pullRawPayload`'s rich-text branch needs
  /// (`fallbackPlainText`).
  public static func winningMimeType(
    for category: ClipboardRepresentationCategory,
    in availableMimeTypes: [String]
  ) -> String? {
    let available = Set(availableMimeTypes)
    for candidate in LinuxClipboardConstants.mimePriority(for: category)
    where available.contains(candidate) {
      return candidate
    }
    return nil
  }

  /// `true` iff any MIME type in `category`'s priority list is present.
  public static func isAvailable(
    _ category: ClipboardRepresentationCategory,
    in availableMimeTypes: [String]
  ) -> Bool {
    winningMimeType(for: category, in: availableMimeTypes) != nil
  }

  /// Every MIME type in `category`'s priority list that appears in
  /// `availableMimeTypes`, in priority order — unlike `winningMimeType`,
  /// this does NOT stop at the first match. `LinuxPasteboard` uses this
  /// for `.richText` so a single capture can preserve every rich
  /// representation a source app offers (e.g. LibreOffice Writer
  /// routinely offers BOTH `text/html` and `text/rtf` for one copy — see
  /// `LinuxRichTextBundle`'s doc comment for how those get bundled into
  /// the one blob slot `ClipnestCore` has room for). Every other category
  /// still only ever needs its single winning representation (there's no
  /// equivalent "richer alternate format" question for a file URI list or
  /// a single image), so `winningMimeType` remains what they call.
  public static func allAvailableMimeTypes(
    for category: ClipboardRepresentationCategory,
    in availableMimeTypes: [String]
  ) -> [String] {
    let available = Set(availableMimeTypes)
    return LinuxClipboardConstants.mimePriority(for: category).filter(available.contains)
  }
}
