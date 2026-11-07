// ItemEditorTagNames.swift
//
// T-EDIT9: the pure half of the Linux item editor's `GtkTextBuffer` styling.
// A run's style is expressed as a set of NAMED `GtkTextTag`s (`b`, `i`, `u`,
// `color:#rrggbb`, `family:<name>`, `size:<pt>`); the window creates a tag
// lazily the first time a name is needed and reads the buffer back by asking
// which named tags cover each stretch of text. Names are the single contract
// between "run -> tags" and "tags -> run", so both directions live here, free
// of any GTK call, and are unit-tested without a display.
import ClipnestCore

enum ItemEditorTagNames {
  static let bold = "b"
  static let italic = "i"
  static let underline = "u"
  static let colorPrefix = "color:"
  static let familyPrefix = "family:"
  static let sizePrefix = "size:"

  /// The tag names that express `run`'s style, sorted so the result is
  /// stable. A run with no formatting has none.
  static func name(for run: StyledRun) -> [String] {
    var names: [String] = []
    if run.bold { names.append(bold) }
    if run.italic { names.append(italic) }
    if run.underline { names.append(underline) }
    if let colorHex = run.colorHex { names.append(colorPrefix + colorHex.lowercased()) }
    if let family = run.fontFamily { names.append(familyPrefix + family) }
    if let size = run.fontSizePt { names.append(sizePrefix + "\(size)") }
    return names.sorted()
  }

  /// The inverse of `name(for:)`: the style (with empty `text`) named by
  /// `names`. Unknown names are ignored. `color:` round-trips to the
  /// uppercase `#RRGGBB` form `StyledRun` documents.
  static func style(fromTagNames names: [String]) -> StyledRun {
    var run = StyledRun(text: "")
    for name in names {
      switch name {
      case bold: run.bold = true
      case italic: run.italic = true
      case underline: run.underline = true
      default:
        if let value = name.dropPrefix(colorPrefix) {
          run.colorHex = value.uppercased()
        } else if let value = name.dropPrefix(familyPrefix) {
          run.fontFamily = value
        } else if let value = name.dropPrefix(sizePrefix), let size = Double(value) {
          run.fontSizePt = size
        }
      }
    }
    return run
  }

  /// The tag names used by `spans`, de-duplicated (what the window must
  /// create before applying the spans).
  static func tagNames(for spans: [StyleSpan]) -> [String] {
    Array(Set(spans.flatMap { name(for: $0.run) })).sorted()
  }
}

extension String {
  fileprivate func dropPrefix(_ prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}
