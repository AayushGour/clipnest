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
// coding-standards.md's Persistence/module-layout section); this SF-Symbol
// mapping is a UI-layer concern, so it lives here in `ClipnestApp` as an
// extension rather than on the model type.
import ClipnestCore

extension ItemKind {
  /// The SF Symbol name used everywhere this kind needs a compact icon.
  var sfSymbolName: String {
    switch self {
    case .text: return "doc.plaintext"
    case .richText: return "doc.richtext"
    case .link: return "link"
    case .image: return "photo"
    case .file: return "doc"
    }
  }
}
