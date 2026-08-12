// ExpandingIconButton.swift
//
// Routed follow-up (2026-08-10): a reusable "expanding icon button"
// micro-interaction — icon-only at rest; on hover the icon slides to the
// leading edge and a title slides in from the trailing edge in one smooth
// motion, widening the button to fit both; on hover-out it collapses back
// to icon-only. First consumer: `TypeFilterChips` (see that file), which
// used to be a plain icon-only `Button` with a `.help` tooltip as the only
// way to learn a chip's name — this makes the name visible in-place on
// hover instead, while keeping the tooltip as an accessibility/discovery
// fallback. Built generic (icon/title/isActive/action, no picker-specific
// knowledge) specifically so it could be reused for other icon-only
// controls later.
//
// Same-day follow-up: now also the *only* row-action button — `ItemRow.swift`
// (pin/unpin, save-as-snippet, delete) and `SnippetRow.swift` (edit, delete)
// both migrated their trailing actions from the old, now-deleted
// `RowActionButton` to this component, reusing it as-is (no new parameters
// needed): `isActive` stays at its default `false` for every row action —
// none of pin/save/delete/edit is a "selected among alternatives" control
// the way a filter chip is, so none gets the active tint/background: pinned
// state keeps communicating itself the same way it always did, via the icon
// glyph (`pin` vs `pin.fill`) and the dynamic title, not via this
// component's `isActive` styling. Multiple instances can sit side by side
// in the same row (ItemRow has up to three) with no extra coordination
// needed — `isHovering` is already per-instance `@State` (see below), so
// only the one instance under the cursor ever expands; the row's own
// content (a `Spacer`-pushed, `.lineLimit(1)`-truncated text block) absorbs
// the width change the same way `PickerView.header`'s search field already
// does when a filter chip expands.
//
// New `UI/Components/` folder: extends (not replaces) the module layout in
// coding-standards.md, which only lists `UI/Picker/` and `UI/Settings/` —
// this is the first control with zero Picker-specific or Settings-specific
// knowledge, so it gets its own home for future shared controls rather than
// living inside `UI/Picker/` where nothing before it needed a "shared
// across features" shelf.
//
// Layout mechanics (horizontal-only expansion, by construction not luck):
// the content `HStack` (icon, optionally followed by title) sits inside a
// frame pinned to an *exact* height (`Self.compactSize`) and only a
// *minimum* width (also `Self.compactSize`) — never a maximum. At rest,
// content is just the icon, narrower than `compactSize`, so the frame pads
// it up to a centered square. On hover, horizontal padding + the title
// `Text` push the content's ideal width past `compactSize`; since width has
// no ceiling, the frame simply grows to fit exactly — no slack — which
// leaves the icon sitting at the leading edge and the title at the trailing
// edge of the now-wider button. That reflow is what reads as "icon slides
// left / title slides in from the right"; it's ordinary SwiftUI layout, not
// a manual offset animation, wrapped in one `withAnimation` per hover-state
// change so the width change, the padding change, and the title's
// insertion/removal transition all animate together. Height is pinned
// exactly (min == max), never just a minimum, so this control can never
// grow vertically regardless of font metrics — the one hard constraint the
// task called out (no vertical jump in the header row that hosts it).
import SwiftUI

/// An icon-only button that reveals its `title` alongside the icon on
/// hover, widening smoothly, and collapses back to icon-only on hover-out.
/// Only the hovered instance expands — `isHovering` is private `@State`
/// local to each instance, so two instances in the same row (e.g. a row's
/// pin + delete buttons) never affect each other's expand state.
struct ExpandingIconButton: View {
  let systemName: String
  let title: String
  /// Optional active/selected styling (bolder icon + tinted background) —
  /// e.g. the currently-selected type filter. Defaults to `false` so
  /// callers with no notion of "active" (a plain icon button) don't need to
  /// pass anything.
  var isActive: Bool = false
  let action: () -> Void

  @State private var isHovering = false

  /// Icon-only resting size — a square, matching the icon-only chip design
  /// this replaces (`TypeFilterChips`'s prior 22×22pt buttons).
  private static let compactSize: CGFloat = 22
  private static let horizontalPadding: CGFloat = 8
  private static let contentSpacing: CGFloat = 4
  private static let cornerRadius: CGFloat = 5
  private static let fontSize: CGFloat = 11
  /// Within the task's asked 0.18–0.22s range.
  private static let animationDuration: Double = 0.2
  private static let activeBackgroundOpacity: Double = 0.2
  private static let hoverBackgroundOpacity: Double = 0.12

  var body: some View {
    Button(action: action) {
      HStack(spacing: isHovering ? Self.contentSpacing : 0) {
        Image(systemName: systemName)
          .font(.system(size: Self.fontSize, weight: isActive ? .semibold : .regular))
        if isHovering {
          Text(title)
            .font(.system(size: Self.fontSize, weight: isActive ? .semibold : .regular))
            .lineLimit(1)
            .fixedSize()
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
      }
      .foregroundStyle(isActive ? .primary : .secondary)
      .padding(.horizontal, isHovering ? Self.horizontalPadding : 0)
      .frame(
        minWidth: Self.compactSize, minHeight: Self.compactSize, maxHeight: Self.compactSize
      )
      .background {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
          .fill(backgroundColor)
      }
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: Self.animationDuration)) {
        isHovering = hovering
      }
    }
    .help(title)
    .accessibilityLabel(title)
  }

  private var backgroundColor: Color {
    if isActive { return Color.secondary.opacity(Self.activeBackgroundOpacity) }
    if isHovering { return Color.secondary.opacity(Self.hoverBackgroundOpacity) }
    return Color.clear
  }
}
