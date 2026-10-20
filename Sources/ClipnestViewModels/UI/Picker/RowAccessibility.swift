// RowAccessibility.swift
//
// T-AUD-VO: pure builders for the picker rows' assistive-technology
// (VoiceOver / Orca) labels and custom-action names. Rows used to be
// `.onTapGesture` containers with no label, trait, or actions, so a screen
// reader announced nothing useful. Each row is now ONE accessibility element
// whose label comes from here; the views (SwiftUI `ItemRow`/`SnippetRow`, the
// GTK row widgets) never build these strings themselves.
//
// The relative time is passed in as text (`RelativeTimeText.string`) so the
// builder is deterministic under test.
import ClipnestCore
import Foundation

public enum RowAccessibility {
  /// Longest preview excerpt spoken in a label before it is cut with "…".
  static let previewCharacterLimit = 80
  private static let ellipsis = "\u{2026}"
  private static let pinnedWord = "pinned"
  private static let multiplicationSign = "\u{00D7}"
  private static let spokenByWord = " by "
  private static let snippetWord = "Snippet"
  private static let keywordWord = "keyword"
  private static let recognizedTextWord = "has recognized text"

  /// Custom-action names (VoiceOver rotor "Actions" / Orca). One definition
  /// each, shared with the context menus' wording.
  public enum ActionName {
    public static let pin = "Pin"
    public static let unpin = "Unpin"
    public static let delete = "Delete"
    public static let saveAsSnippet = "Save as Snippet"
    public static let pastePlainText = "Paste as plain text"
    public static let copyRecognizedText = "Copy Recognized Text"
    public static let edit = "Edit"
  }

  /// "Text, pinned, 2 minutes ago: first 80 characters" /
  /// "Image, 1200 by 800, 5 minutes ago".
  public static func itemLabel(for item: ClipItem, relativeTime: String) -> String {
    var parts: [String] = []
    let excerpt = excerpt(of: item.previewText)
    if item.kind == .image {
      // Captured image rows carry "Image, 1200×800" as their preview text
      // (`PasteboardReader.imagePreviewText`) — speak it as "1200 by 800".
      parts.append(spokenDimensions(in: excerpt))
    } else {
      parts.append(kindName(item.kind))
    }
    if item.pinned { parts.append(pinnedWord) }
    if item.hasRecognizedText { parts.append(recognizedTextWord) }
    parts.append(relativeTime)
    let header = parts.joined(separator: ", ")
    guard item.kind != .image, !excerpt.isEmpty else { return header }
    return "\(header): \(excerpt)"
  }

  /// "Snippet Greeting, keyword hi: Hello there…" (keyword omitted when none).
  public static func snippetLabel(for snippet: Snippet) -> String {
    var header = "\(snippetWord) \(snippet.title)"
    if let keyword = snippet.keyword, !keyword.isEmpty {
      header += ", \(keywordWord) \(keyword)"
    }
    let body = excerpt(of: snippet.body)
    return body.isEmpty ? header : "\(header): \(body)"
  }

  /// Whether "Paste as plain text" differs from the default paste for `item`
  /// (same truth as the footer's ⌥⏎ hint — `HighlightedItemCapabilities`).
  public static func supportsPlainTextPaste(_ item: ClipItem) -> Bool {
    HighlightedItemCapabilities(item: item).altEnterHint != nil
  }

  static func kindName(_ kind: ItemKind) -> String {
    switch kind {
    case .text: return "Text"
    case .richText: return "Rich text"
    case .link: return "Link"
    case .image: return "Image"
    case .file: return "File"
    }
  }

  /// Input is bounded BEFORE any O(n) work (previews can be megabytes and this
  /// runs on main per row render / arrow-key announcement): only the first
  /// `previewCharacterLimit * inputBoundFactor` characters are examined.
  private static let inputBoundFactor = 4

  /// Whitespace-collapsed, trimmed, cut to `previewCharacterLimit`; an
  /// ellipsis marks any cut, including when the bounded input was shorter than
  /// the original.
  static func excerpt(of text: String) -> String {
    let bound = previewCharacterLimit * inputBoundFactor
    let head = text.prefix(bound)
    let wasBounded = !text.dropFirst(bound).isEmpty
    let collapsed =
      head.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    if collapsed.count > previewCharacterLimit {
      return String(collapsed.prefix(previewCharacterLimit)) + ellipsis
    }
    return wasBounded ? collapsed + ellipsis : collapsed
  }

  private static func spokenDimensions(in text: String) -> String {
    text.replacingOccurrences(of: multiplicationSign, with: spokenByWord)
  }
}
