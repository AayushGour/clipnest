// ItemKind+SFSymbol.swift
//
// The one place that maps `ItemKind` to the SF Symbol used to represent it
// in the picker UI. Extracted here once a second call site needed the same
// mapping: `ItemRow`'s leading per-kind icon (`.text`/`.richText`/`.link`
// icons, plus the fallback glyph for `.image`/`.file`'s async thumbnail)
// and the header row's icon-only `TypeFilterChips` (T-UI: type filters
// moved into the search-bar row) both draw the same glyph for the same
// kind — per coding-standards.md's DRY rule, a real second duplicate is
// extracted rather than copy-pasted again. `ItemKind` itself stays a plain
// `ClipnestCore` value type with zero UI-framework knowledge (per
// coding-standards.md's Persistence/module-layout section); this icon
// mapping is a UI-layer concern, not a model concern.
//
// P5 (Phase 3, Linux port): moved from `ClipnestApp` into `ClipnestViewModels`
// so both platforms' UI layers share one place per icon set. SF Symbols are
// an Apple-only glyph namespace with no Linux equivalent, so `sfSymbolName`
// stays `#if os(macOS)`-gated exactly as before (unchanged strings, now
// `public` so `ItemRow`/`TypeFilterChips` in `ClipnestApp` — a different
// module — can still reach it); a GTK/freedesktop icon-theme name table is
// added under `#else` for the future Linux UI, verified against the
// freedesktop.org Icon Naming Specification's standard MimeTypes icon names
// (not yet consumed by any UI — no GTK app exists yet).
import ClipnestCore

extension ItemKind {
  #if os(macOS)
    /// The SF Symbol name used everywhere this kind needs a compact icon.
    public var sfSymbolName: String {
      switch self {
      case .text: return "doc.plaintext"
      case .richText: return "doc.richtext"
      case .link: return "link"
      case .image: return "photo"
      case .file: return "doc"
      }
    }
  #else
    /// The freedesktop.org Icon Naming Specification MimeTypes icon name
    /// used everywhere this kind needs a compact icon on a GTK-based Linux
    /// UI — the non-Apple counterpart to `sfSymbolName` above. Not yet
    /// consumed by any UI (no GTK app exists yet); added here so the
    /// mapping lives in exactly one place the moment one does.
    public var gtkIconName: String {
      switch self {
      case .text: return "text-x-generic"
      case .richText: return "x-office-document"
      case .link: return "insert-link"
      case .image: return "image-x-generic"
      case .file: return "application-x-generic"
      }
    }
  #endif
}
