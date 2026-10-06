// ItemRowActionContent.swift
//
// Linux parity pass (routed follow-up, 2026-09-06): pure gating logic for a
// History/Pinned row's actions — mirrors macOS `ItemRow.swift` exactly:
// three always-visible trailing icon buttons (pin/unpin, save-as-snippet,
// delete) PLUS a right-click context menu offering those same three actions
// plus a fourth, menu-only action ("Copy Recognized Text"). See that file's
// doc comment for the full history of why macOS settled on this exact split
// (T24/T42/T-OCR2/T-SET4).
//
// Ownership note: this task's owned-files scope is `Sources/ClipnestGTK/
// Window/*.swift` only — NOT `Support/ClipItemRowContent.swift` (a sibling
// agent's territory this session) — so this pure, GTK-free content type
// lives here instead of alongside `ClipItemRowContent`/`SnippetRowContent`,
// where it would otherwise belong by convention. `PickerWindow+Rows.swift`
// (also owned) is the only caller.
//
// Single source of truth (coding-standards.md DRY): every gating predicate
// below reads `ClipItem.supportsSaveAsSnippet`/`.hasRecognizedText`
// (`ClipnestCore/Model/ClipItemOCR.swift`) — the exact same properties the
// picker footer's ⌥⏎/⌘S hints and macOS's `ItemRow` already depend on. This
// file does not re-derive either predicate.
//
// `buttons(for:)` and `contextMenu(for:)` are two FILTERS over one shared,
// privately-built entry list (`gatedEntries(for:)`) rather than two
// independently-written entry lists — so "Pin"/"Unpin"'s label and gating
// (and every other entry's) is written exactly once, per the routing
// instruction ("Reuse one action per behavior across both surfaces exactly
// as macOS does — do not write the pin action twice"). Order matches macOS:
// Pin/Unpin, [Save as Snippet if supported], [Copy Recognized Text if
// present — context menu only], Delete.
import ClipnestCore

/// One row action a History/Pinned row can offer — shared by both the
/// always-visible trailing buttons and the right-click context menu.
/// `PickerWindow+RowActions.swift` is the single place that dispatches each
/// case to the matching `PickerViewModel` call.
public enum ItemRowAction: Equatable, Sendable {
  case togglePin
  case saveAsSnippet
  case copyRecognizedText
  case delete
}

/// One fully-resolved entry — action plus its already-decided display
/// label and destructive styling — ready for `PickerWindow+Rows.swift`/
/// `PickerWindow+ContextMenu.swift` to render without any gating logic of
/// their own.
public struct ItemRowActionEntry: Equatable, Sendable {
  public let action: ItemRowAction
  public let label: String
  public let isDestructive: Bool
}

public enum ItemRowActions {
  /// Whether `entry` belongs on the always-visible trailing button row.
  /// `.copyRecognizedText` is the one action macOS never renders as a
  /// button — see `ItemRow.rowActions`'s doc comment ("not a fourth
  /// always-visible button ... copying it lives in the context menu").
  private static func isButtonEligible(_ action: ItemRowAction) -> Bool {
    action != .copyRecognizedText
  }

  /// The single, ordered list of entries `item` supports — computed once,
  /// then filtered by each public accessor below. `item.pinned`'s label
  /// (`"Unpin"`/`"Pin"`) is resolved exactly once, here.
  private static func gatedEntries(for item: ClipItem) -> [ItemRowActionEntry] {
    var entries: [ItemRowActionEntry] = [
      ItemRowActionEntry(
        action: .togglePin, label: item.pinned ? "Unpin" : "Pin", isDestructive: false)
    ]
    if item.supportsSaveAsSnippet {
      entries.append(
        ItemRowActionEntry(action: .saveAsSnippet, label: "Save as Snippet", isDestructive: false)
      )
    }
    if item.hasRecognizedText {
      entries.append(
        ItemRowActionEntry(
          action: .copyRecognizedText, label: "Copy Recognized Text", isDestructive: false))
    }
    entries.append(ItemRowActionEntry(action: .delete, label: "Delete", isDestructive: true))
    return entries
  }

  /// The row's always-visible trailing icon buttons — exactly two or three
  /// (pin, [save as snippet], delete), matching `ItemRow.rowActions`: no
  /// dead button renders for a kind that doesn't support saving as a
  /// snippet (`.richText`/`.image`/`.file`).
  public static func buttons(for item: ClipItem) -> [ItemRowActionEntry] {
    gatedEntries(for: item).filter { isButtonEligible($0.action) }
  }

  /// The row's right-click context-menu entries — everything `buttons(for:)`
  /// offers, plus "Copy Recognized Text" when the item has recognized text.
  /// Matches `ItemRow.body`'s `.contextMenu` exactly, including order.
  public static func contextMenu(for item: ClipItem) -> [ItemRowActionEntry] {
    gatedEntries(for: item)
  }
}
