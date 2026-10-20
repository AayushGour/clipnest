// TypeFilterChips.swift
//
// Rich per-kind row previews landed a leading thumbnail/icon per
// `ItemKind`; this is the matching filter control — a compact row of
// icon-only chips (All / Text / Image / File / Link) that narrows the
// active tab's list to one kind via the existing `SearchQuery.kindFilter`
// (honored by `ClipStore.query(text:kind:scope:offset:limit:)` — T50/T51
// moved this filtering into the store; see `PickerViewModel`'s top doc
// comment).
//
// UI change: moved out of its own standalone row (below the search field)
// and into the trailing edge of the search-bar row itself — see
// `PickerView.header`. That move is also why this went icon-only: at the
// search row's height, text chips (the original design) crowded the
// search field; a single SF Symbol per kind reads clearly at a much
// smaller footprint and stays legible next to the field. Icons reuse the
// exact glyphs `ItemRow` already draws for each kind (`ItemKind.sfSymbolName`,
// see that extension's doc comment) so a kind is never drawn with two
// different symbols across the picker.
//
// Routed follow-up (2026-08-10): each chip is now the new reusable
// `ExpandingIconButton` (see `UI/Components/ExpandingIconButton.swift`)
// instead of a plain icon-only `Button` — on hover, the chip's name slides
// in next to the icon instead of being discoverable only via the `.help`
// tooltip (still present as a fallback, owned by `ExpandingIconButton`
// itself now rather than duplicated here). The active-filter highlight and
// all filtering behavior (`SearchQuery.kindFilter`, "All" = no filter,
// persists across tabs) are unchanged — only the chip's own rendering
// moved into the shared component.
//
// T-AUD-KBD / T-AUD-VO: the ACTIVE chip now stays expanded (icon + name) so the
// current filter is readable without hovering, and every chip speaks its full
// name ("Images filter") with the selected trait on the active one. Order,
// names and ⌘[ / ⌘] cycling live in `KindFilterOptions`.
import ClipnestCore
import ClipnestViewModels
import SwiftUI

/// Filters the active tab's list by `ItemKind` via `selection`
/// (`SearchQuery.kindFilter`, bound directly from `PickerView` the same way
/// the search field binds `SearchQuery.text` — see that call site). `nil`
/// ("All") is always the first option and clears the filter entirely.
///
/// Deliberately NOT `ItemKind.allCases` (which also includes `.richText`) —
/// this control offers exactly the 5 options the task spec names; a
/// `.richText` item is only reachable via "All", not a dedicated chip.
struct TypeFilterChips: View {
  @Binding var selection: ItemKind?

  /// "All" has no backing `ItemKind` to source a glyph from (see
  /// `ItemKind+SFSymbol.swift`), so its icon is defined once, here.
  private static let allSymbolName = "square.grid.2x2"

  var body: some View {
    HStack(spacing: 2) {
      ForEach(KindFilterOptions.macOptions, id: \.self) { option in
        chip(for: option)
      }
    }
  }

  /// Names, order and cycling live in `KindFilterOptions` (shared with Linux
  /// and with the ⌘[ / ⌘] shortcut). The active chip shows its title; every
  /// chip speaks its full name ("Images filter") and the active one carries
  /// the selected trait (T-AUD-VO / T-AUD-KBD).
  private func chip(for option: ItemKind?) -> some View {
    ExpandingIconButton(
      systemName: option?.sfSymbolName ?? Self.allSymbolName,
      title: KindFilterOptions.title(for: option),
      isActive: selection == option,
      accessibilityLabelOverride: KindFilterOptions.accessibilityLabel(for: option),
      action: { selection = option }
    )
  }
}
