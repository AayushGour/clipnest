// KindFilterOptions.swift
//
// T-AUD-KBD / T-AUD-VO: the type-filter chip set, its display names, its
// assistive-technology labels, and the cycling order behind the "next/previous
// filter" shortcut. Shared by macOS (`TypeFilterChips`, `PickerView`) and
// Linux (`PickerWindow+Chips`/`+Keyboard`) so the order and the names are
// defined exactly once.
import ClipnestCore

public enum KindFilterOptions {
  /// The macOS chip set, in display order: "All" (`nil`) first. Deliberately
  /// not `ItemKind.allCases` — `.richText` is only reachable via "All".
  public static let macOptions: [ItemKind?] = [nil, .text, .image, .file, .link]

  /// The Linux chip set: "All" plus every kind (the GTK picker also offers a
  /// Rich Text chip).
  public static let linuxOptions: [ItemKind?] = [nil] + ItemKind.allCases.map { Optional($0) }

  static let allTitle = "All"

  /// Short visible name ("All", "Text", "Rich Text", ...).
  public static func title(for option: ItemKind?) -> String {
    guard let option else { return allTitle }
    switch option {
    case .text: return "Text"
    case .richText: return "Rich Text"
    case .link: return "Link"
    case .image: return "Image"
    case .file: return "File"
    }
  }

  /// Full assistive-technology name: "All items filter", "Images filter".
  public static func accessibilityLabel(for option: ItemKind?) -> String {
    guard let option else { return "All items filter" }
    switch option {
    case .text: return "Text filter"
    case .richText: return "Rich text filter"
    case .link: return "Links filter"
    case .image: return "Images filter"
    case .file: return "Files filter"
    }
  }

  /// The option `step` positions after (`+1`) or before (`-1`) `current` in
  /// `options`, wrapping at both ends. A `current` that isn't in `options`
  /// (e.g. `.richText` against the macOS set) restarts from "All".
  public static func cycled(
    from current: ItemKind?, in options: [ItemKind?], step: Int
  ) -> ItemKind? {
    guard !options.isEmpty else { return current }
    guard let index = options.firstIndex(where: { $0 == current }) else { return options[0] }
    let count = options.count
    return options[((index + step) % count + count) % count]
  }
}
