// ItemKindChipLabel.swift
//
// P7-D (Linux port, GTK4 view layer): the type-filter chips' display text —
// the Linux counterpart of macOS's `TypeFilterChips.swift` (an
// icon-plus-tooltip `SwiftUI` view; its labels aren't exposed as a
// standalone testable value, so this is a fresh mapping, not an extraction).
// `ItemKind.gtkIconName` (already defined in
// `ClipnestViewModels/UI/Picker/ItemKind+SFSymbol.swift`) supplies each
// chip's icon; this file supplies its text. Kept in `ClipnestGTK` (not
// `ClipnestViewModels`, unlike `gtkIconName`) because it's this task's own
// scope (`Sources/ClipnestGTK/**` only) and nothing else needs it yet — if
// a second Linux UI surface needs the same label, it should move up to
// `ClipnestViewModels` alongside `gtkIconName` at that point, mirroring why
// `gtkIconName` itself lives there instead of duplicated per call site.
import ClipnestCore
import ClipnestViewModels

public enum ItemKindChipLabel {
  /// The chip label shown for `kind` in the picker's type-filter row. Delegates
  /// to the shared `KindFilterOptions.title(for:)` (T-AUD-KBD) so the macOS and
  /// Linux names can't drift.
  public static func label(for kind: ItemKind) -> String {
    KindFilterOptions.title(for: kind)
  }
}
