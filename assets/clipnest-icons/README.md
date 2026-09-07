# Clipnest icon set

Clean vector icon set derived from the Clipnest logo (`clipnest-logo.png`): a woven
nest cradling a fan of clipboard cards. The master is a hand-refined 5-layer vector
(paper, peach, purple, nest, text lines). Every treatment is composed from those same
paths, so the whole set stays consistent.

All files are self-contained SVG. Monochrome variants use `currentColor` — set CSS
`color` (or the `color:` inline style) to recolor.

## Files

| File | Treatment | Use |
|------|-----------|-----|
| `clipnest-color.svg` | Color (master) | The refined brand mark — general use, marketing, docs |
| `clipnest-duotone.svg` | Duotone (single hue) | Cards tinted, nest + text solid. Recolor via `color` |
| `clipnest-outline.svg` | Outline / line | Line-art: cards stroked + thin traced nest + solid text bars. Recolor via `color` |
| `clipnest-mono.svg` | Solid monochrome glyph | SF-Symbols-style silhouette, text lines punched. Recolor via `color` |
| `clipnest-menubar-template.svg` | macOS menu-bar template | Pure black, reads at 16–18 px. Use as an `NSImage` **template** |
| `clipnest-app-icon.svg` | macOS app icon | 1024 squircle tile, soft bg + drop shadow |
| `app.clipnest.Clipnest-symbolic.svg` | Linux tray (freedesktop symbolic) | Same glyph as `clipnest-mono.svg` (same `<path>`/`<mask>` data, byte-for-byte), fill hardcoded to `#bebebe` instead of `currentColor` — most `org.kde.StatusNotifierItem` hosts render the raw file rather than doing GTK4's class-based live recolor, so the fallback fill has to look right on its own. Installed to `hicolor/symbolic/apps/` by `debian/rules`; referenced as `IconName = "app.clipnest.Clipnest-symbolic"` in `StatusNotifierNames.swift`. |

Canvas: the color master and glyph treatments use `viewBox 0 0 908 908`; the app icon uses `0 0 1024 1024`.

## Brand colors

| Token | Hex |
|-------|-----|
| Purple card | `#C6BEDC` |
| Peach card | `#E7CEB0` |
| Paper | `#F9F0E2` |
| Nest | `#9F7750` |
| Text lines | `#C1B09C` |
| App-icon tile | `#FCFBF8` → `#EDE7DD` |

Monochrome default inks: mono `#26221E`, duotone `#6E4E33`, outline `#4A3A2C` — all overridable via `color`.

## Recolor examples

```html
<!-- outline/mono/duotone follow currentColor -->
<div style="color:#333">…inline the svg…</div>
```

## Menu-bar note

`clipnest-menubar-template.svg` is meant to be rendered to `@1x`/`@2x` PNG and set as a
**template image** (`image.isTemplate = true`) so macOS tints it for light/dark menu bars.

## PNG / ICNS export

Raster export (AppIcon.appiconset at 16→1024, `.icns`, menu-bar `@1x/@2x`, favicon) can be
generated from these SVGs on request — not yet built.
