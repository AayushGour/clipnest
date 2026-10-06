// PickerStyleSheet.swift
//
// Routed follow-up ("make the GTK4 picker look close to the shipping macOS
// SwiftUI picker"): the picker's ONE stylesheet — every visual token this
// module applies to `PickerWindow`'s widgets lives here, in its own file,
// so `ClipnestGTKApplication.installStyle()` (which loads it once at
// startup) stays a plain two-line call and every class name this file
// defines has exactly one place backing it.
//
// WHY AN EMBEDDED SWIFT STRING, NOT A LOOSE `.css` FILE LOADED VIA
// `gtk_css_provider_load_from_path`: a loose file needs a stable installed
// path SwiftPM's `resources:` bundling (`Bundle.module`) can produce, but
// whether `debian/rules`/`dpkg-buildpackage` (out of this task's file
// scope — `packaging/**` beyond the VNC test Dockerfile was never touched)
// actually stages that generated resource bundle into the shipped `.deb`
// alongside the `clipnest` binary is unverified and a real risk of a
// "looks fine in dev, ships broken" regression. Compiling the CSS directly
// into the binary as a `String` constant has zero packaging surface: it is
// present anywhere the binary runs, dev container or shipped `.deb`, with
// no install-path to get wrong. The content below is still genuine GTK CSS
// (copy it out verbatim to lint/preview it), just carried in a `.swift`
// file instead of a `.css` one.
//
// DESIGN TOKENS — every value below is either lifted verbatim from the
// macOS SwiftUI picker's source (`ClipnestApp/Sources/UI/Picker/*.swift`,
// read-only reference for this task) or a documented GTK equivalent where
// macOS has no literal analog (system materials, semantic colors, the
// window's system-default corner radius). See this task's report for the
// full macOS-value → GTK-token table; the short version, matched to the
// CSS rules below:
//
//  - Window: macOS's `PickerPanel` sets NO explicit corner radius in code
//    — the rounded corners the shipping app shows come from macOS's own
//    system-default window rounding (every standard/floating window has
//    gotten this since Big Sur, more pronounced under the newer "Liquid
//    Glass" material). The 10px radius below approximates that system
//    default; it isn't extracted from a literal because macOS has no
//    literal to extract. The background approximates SwiftUI's
//    `.regularMaterial` (a blurred, semi-opaque system material) with a
//    theme-adaptive translucent fill — GTK has no compositor-level blur
//    available from CSS alone, so this is the closest achievable "material"
//    look; see the report's gap list.
//  - Rows: `ItemRow`/`SnippetRow` pad `.vertical, 4` with an outer `HStack`
//    spacing of 10 and a leading icon `.frame(width: 18)` (thumbnails
//    render at 20×20) — the row padding/spacing below and
//    `PickerWindow.rowIconPixelSize`/`.rowSpacing` (`PickerWindow+Rows.swift`)
//    mirror these. Title text is unstyled `Text` (system `.body`, 13pt); the
//    timestamp/source-app line is `.font(.caption)` + `.secondary`
//    (~10pt, ~60%-opacity label) — GTK's stock `.dim-label` class (already
//    used in six places pre-existing in this module) already renders
//    exactly that "secondary label" look (~55% opacity), so it's reused
//    rather than reinvented; this stylesheet only adds the matching font
//    size on top of it.
//  - Selection: macOS's `List(selection:)` in `.plain` style (what
//    `PickerView`'s `ScrollResettingList` uses) paints a translucent,
//    rounded, ACCENT-tinted highlight behind the selected row's content —
//    it does NOT invert row text to white the way a `.sourceList`/Finder-
//    style selection does. GTK's stock `GtkListBox` row selection is the
//    opposite default (solid `@theme_selected_bg_color` fill + white
//    text) — `list.picker-list row:selected` below overrides both halves
//    of that to match macOS's actual look instead of GTK's default one.
//  - Tabs / chips: `TabSwitcher`'s active pill is `Color.secondary
//    .opacity(0.2)` behind `.caption`, bold-when-selected text — NOT
//    accent-colored. `TypeFilterChips`/row actions share
//    `ExpandingIconButton`'s tokens (22pt compact square, 5pt corner
//    radius, 11pt icon font, 0.2/0.12 opacity active/hover fills). Both
//    map to `@theme_fg_color` at those exact opacities (a neutral gray
//    wash, matching `Color.secondary`, not `Color.accentColor`) — GTK's
//    `.picker-tab`/`.picker-chip` classes below reuse `:checked` (the
//    pseudo-class `GtkToggleButton` already carries for its active state)
//    instead of a second Swift-side "active" CSS class, so no signal
//    handler needs touching to keep the visual in sync with state.
//  - Divider color: SwiftUI's plain `Divider()` renders as `.separatorColor`
//    (a very low-contrast ~10%-opacity hairline). `alpha(@borders, 0.5)`
//    approximates it; GTK's `@borders` named color is itself already a
//    low-contrast theme border tone, so 0.5 (not 1.0) keeps it hairline-thin
//    rather than a solid rule.
//
// LIGHT/DARK: every color reference below is a GTK NAMED theme color
// (`@theme_bg_color`, `@theme_fg_color`, `@theme_selected_bg_color`,
// `@borders`) run through `alpha(...)`, never a literal hex value — GTK's
// theme engine (Adwaita/Yaru, whichever is active) already redefines each
// of these per `gtk-application-prefer-dark-theme`/the user's GTK theme
// choice, so this ONE stylesheet renders correctly in both without a
// separate dark-mode branch, matching how `.dim-label`/`.secondary`/
// `.primary` already work today.
enum PickerStyleSheet {
  static let css = """
    /* ===== Window: corner radius + translucent "material" background =====
       See this file's top doc comment for why these two values have no
       literal macOS source to extract from. */
    window.picker-window {
      background-color: alpha(@theme_bg_color, 0.94);
      border: 1px solid alpha(@borders, 0.6);
      border-radius: 10px;
    }
    /* Fallback for a NON-composited display (`gdk_display_is_composited`
       false — checked once at window construction, see `PickerWindow
       .swift`'s `init`): a rounded, alpha-clipped corner with no
       compositor to blend it against the desktop renders as a solid BLACK
       wedge instead of a soft edge — worse than square corners, not
       better. Same family of fallback GTK's own CSD ships (`.solid-csd`
       drops shadow/rounding when uncomposited); this is that same
       defensive choice applied to this custom class. Opaque fill (no
       alpha) + no radius — a plain, correct-looking flat panel. */
    window.picker-window-flat {
      background-color: @theme_bg_color;
      border: 1px solid alpha(@borders, 0.8);
    }

    /* ===== Search field (searchEntry): macOS's is a borderless, plain-text
       field flush with the header row — strip GtkSearchEntry's default
       pill/frame chrome to match, keep its built-in magnifier/clear icons. */
    entry.picker-search {
      background: transparent;
      border: none;
      box-shadow: none;
      outline: none;
      padding: 4px 2px;
      font-size: 13pt;
    }
    /* GTK4 draws an entry's focus ring via the separate CSS `outline`
       property (NOT `border`/`box-shadow`) — resetting only the latter two
       (as this rule first did) still left the ring visible; see this
       task's report for how that was diagnosed. */
    entry.picker-search:focus,
    entry.picker-search:focus-within {
      outline: none;
      box-shadow: none;
    }
    entry.picker-search image {
      opacity: 0.6;
    }

    /* ===== Header/tab-row dividers — approximates PickerView's plain
       SwiftUI `Divider()` between the header, tab bar, and content. */
    box.picker-header-row {
      border-bottom: 1px solid alpha(@borders, 0.5);
      padding-bottom: 4px;
    }
    box.picker-tab-row {
      border-bottom: 1px solid alpha(@borders, 0.5);
      padding-bottom: 4px;
    }

    /* ===== Tab switcher (History/Pinned/Snippets) — TabSwitcher.swift:
       caption-size text, secondary-gray active pill (NOT accent-colored),
       bold when selected. */
    button.picker-tab {
      font-size: 10pt;
      padding: 4px 10px;
      border-radius: 6px;
      background: transparent;
      border: none;
      box-shadow: none;
      color: alpha(@theme_fg_color, 0.65);
    }
    button.picker-tab:checked {
      background-color: alpha(@theme_fg_color, 0.2);
      color: @theme_fg_color;
      font-weight: 600;
    }
    button.picker-tab:hover {
      background-color: alpha(@theme_fg_color, 0.08);
    }

    /* ===== Type-filter chips — ExpandingIconButton's tokens:
       22pt compact square, 5px corner radius, 0.2/0.12 active/hover fill. */
    button.picker-chip {
      min-width: 22px;
      min-height: 22px;
      padding: 3px;
      border-radius: 5px;
      background: transparent;
      border: none;
      box-shadow: none;
      color: alpha(@theme_fg_color, 0.65);
    }
    button.picker-chip:checked {
      background-color: alpha(@theme_fg_color, 0.2);
      color: @theme_fg_color;
    }
    button.picker-chip:hover {
      background-color: alpha(@theme_fg_color, 0.12);
    }

    /* ===== Rows (History/Pinned/Snippets) =====
       GtkListBox's stock "view"/"content list" look is an opaque white
       (`@theme_base_color`) fill, independent of the window's own
       background — macOS has no such seam: the whole picker, list
       included, shares one `.regularMaterial` fill top to bottom. Clearing
       both nodes to transparent lets the window's own translucent fill
       (or the non-composited flat fallback) show through uniformly. */
    scrolledwindow.picker-scroll,
    scrolledwindow.picker-scroll > viewport {
      background: transparent;
    }
    list.picker-list {
      background: transparent;
    }
    /* ItemRow/SnippetRow: `.padding(.vertical, 4)`, HStack spacing 10. */
    list.picker-list row {
      padding: 4px 8px;
      margin: 1px 4px;
      border-radius: 6px;
    }
    /* macOS's `.plain` List selection: a translucent ACCENT-tinted rounded
       highlight behind the row, text stays its normal (non-inverted)
       color — the opposite of GtkListBox's own solid-fill/white-text
       default, which is why both halves are overridden here. */
    list.picker-list row:selected {
      background-color: alpha(@theme_selected_bg_color, 0.18);
      color: @theme_fg_color;
    }
    list.picker-list row:selected label {
      color: inherit;
    }
    /* A subtle hover wash — macOS's `List` shows an analogous light hover
       highlight on pointer-capable Macs; kept intentionally faint so it
       doesn't compete with the selection highlight above. */
    list.picker-list row:hover {
      background-color: alpha(@theme_fg_color, 0.05);
    }

    .picker-row-title {
      font-size: 13pt;
    }
    .picker-row-meta {
      font-size: 10pt;
    }

    /* ===== Footer hint bar — shortcutHintBar: `.caption2` (~10pt),
       secondary, with a divider above it matching PickerView's Divider(). */
    label.picker-footer {
      font-size: 10pt;
      border-top: 1px solid alpha(@borders, 0.5);
      padding: 4px 4px 0 4px;
    }

    /* ===== Empty state — PickerView.emptyState: `.callout` (~12pt). */
    label.picker-empty {
      font-size: 12pt;
    }
    """
}
