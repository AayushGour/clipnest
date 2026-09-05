// ClipItemRowContent.swift
//
// P7-D (Linux port, GTK4 view layer): pure row-model construction for a
// History/Pinned row — everything `PickerWindow+Rows.swift` (the untestable
// GTK edge) needs to populate one `GtkListBoxRow`'s widgets, computed once
// up front so the GTK-touching code only ever does dumb "set this label's
// markup to that string" calls, never its own icon/highlight/label logic.
// Mirrors macOS's `ItemRow` in spirit (same four ingredients: type icon,
// highlighted preview text, source-app label, pinned badge) without any of
// `ItemRow`'s SwiftUI/AppKit dependency.
import ClipnestCore

public struct ClipItemRowContent: Equatable, Sendable {
  public let id: ClipItem.ID
  /// The freedesktop.org icon name for this item's `ItemKind` (see
  /// `ItemKind.gtkIconName`) — fed to `gtk_image_new_from_icon_name`.
  public let iconName: String
  /// Pango markup (see `PangoMarkup.markup(for:)`) for the row's preview
  /// text, with every occurrence of the active search query highlighted.
  public let markupText: String
  /// The capturing app's display name, or `nil` when unknown — shown as a
  /// trailing, secondary-styled label, matching `ItemRow`'s source-app
  /// text.
  public let sourceAppLabel: String?
  public let isPinned: Bool
  /// Whether this row has on-device-recognized text (`ClipItem
  /// .hasRecognizedText`) — drives the small OCR badge `ItemRow` also
  /// shows on macOS.
  public let hasRecognizedText: Bool

  public init(item: ClipItem, searchText: String) {
    id = item.id
    iconName = item.kind.gtkIconName
    markupText = PangoMarkup.markup(
      for: SearchHighlightSegments.segments(in: item.previewText, matching: searchText))
    sourceAppLabel = item.sourceAppName
    isPinned = item.pinned
    hasRecognizedText = item.hasRecognizedText
  }
}
