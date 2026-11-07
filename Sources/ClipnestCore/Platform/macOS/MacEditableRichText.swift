import Foundation

#if os(macOS)
  import AppKit

  /// RTF codec + format toggles for the rich-text edit popup (macOS).
  ///
  /// Uses the same RTF document type as `MacRichTextFlattener`, so edited
  /// blobs stay byte-format-compatible with captured ones (the stored
  /// `.richText` blob on macOS is raw RTF bytes). Main-actor isolated because
  /// `NSFontManager` is. The codec (`load`, `rtf(from:)` and their helpers) is
  /// `nonisolated`: parsing and the lossy round-trip check can be slow on a
  /// large RTF, so callers run `load` in a detached task and only the finished
  /// value reaches the main actor (project rule: never block main).
  @MainActor
  public enum MacEditableRichText {
    public enum FormatTrait: Sendable, CaseIterable { case bold, italic, underline }

    /// Result of `load`. `isLossy` is true only when re-serializing would
    /// actually drop something (drives the "Some formatting in this item
    /// can't be kept." warning).
    ///
    /// `@unchecked Sendable`: `NSAttributedString` is immutable and `load`
    /// hands over a freshly built, unshared instance exactly once (the
    /// consumer makes its own mutable copy for editing), so crossing from the
    /// worker to the main actor is safe.
    public struct Loaded: @unchecked Sendable {
      public let attributed: NSAttributedString
      public let isLossy: Bool
    }

    /// Editor default: the system font at the standard body size
    /// (`NSFont.systemFontSize`) in the label color — what a plain item looks
    /// like in the editor. Anything differing from this counts as formatting.
    nonisolated(unsafe) public static let defaultAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: NSColor.labelColor,
    ]

    private nonisolated static var rtfOptions: [NSAttributedString.DocumentReadingOptionKey: Any] {
      [.documentType: NSAttributedString.DocumentType.rtf]
    }

    /// Largest stored RTF blob the editor will parse for rich editing (4 MiB:
    /// far above any hand-written note, below sizes where parse + the lossy
    /// round trip would take noticeable time). Bigger blobs open as plain text
    /// with the lossy warning, so Save Anyway still works but never stalls.
    public nonisolated static let maxEditableRTFBytes = 4 * 1024 * 1024

    private nonisolated static let colorTolerance: CGFloat = 0.02

    // MARK: Codec

    /// Parses `rtf` (when present and within `maxRTFBytes`) and decides
    /// `isLossy`. `nonisolated` and potentially slow: call it off the main
    /// actor.
    public nonisolated static func load(
      rtf: Data?, plainText: String, maxRTFBytes: Int = maxEditableRTFBytes
    ) -> Loaded {
      let plain = Loaded(
        attributed: NSAttributedString(string: plainText, attributes: defaultAttributes),
        isLossy: false)
      guard let rtf else { return plain }
      // Too big to parse safely: plain text, flagged as losing its formatting.
      guard rtf.count <= maxRTFBytes else {
        return Loaded(attributed: plain.attributed, isLossy: true)
      }
      // Present but unparseable: the formatting is lost on save.
      guard let parsed = parse(rtf) else {
        return Loaded(attributed: plain.attributed, isLossy: true)
      }
      return Loaded(attributed: parsed, isLossy: isLossy(parsed))
    }

    public nonisolated static func rtf(from attributed: NSAttributedString) -> Data? {
      try? attributed.data(
        from: NSRange(location: 0, length: attributed.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private nonisolated static func parse(_ data: Data) -> NSAttributedString? {
      try? NSAttributedString(data: data, options: rtfOptions, documentAttributes: nil)
    }

    /// Lossy when any run carries an attachment, or serializing to RTF and
    /// reloading does not reproduce the same attributed string. Internal so
    /// tests can exercise the attachment branch directly (the RTF reader
    /// itself never yields attachments from `\pict`).
    nonisolated static func isLossy(_ parsed: NSAttributedString) -> Bool {
      if containsAttachment(parsed) { return true }
      guard let data = rtf(from: parsed), let reloaded = parse(data) else { return true }
      return !withoutNeutralParagraphStyle(parsed).isEqual(
        to: withoutNeutralParagraphStyle(reloaded))
    }

    /// RTF serialization attaches an explicit neutral `NSParagraphStyle` to
    /// every run on reload; that is not a loss, so it must not trip `isLossy`.
    private nonisolated static func withoutNeutralParagraphStyle(_ attributed: NSAttributedString)
      -> NSAttributedString
    {
      let copy = NSMutableAttributedString(attributedString: attributed)
      let full = NSRange(location: 0, length: copy.length)
      attributed.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
        if let style = value as? NSParagraphStyle, isNeutral(style) {
          copy.removeAttribute(.paragraphStyle, range: range)
        }
      }
      return copy
    }

    /// A paragraph style carrying no layout beyond RTF's implicit defaults
    /// (no lists, no custom tab stops). Internal for tests.
    nonisolated static func isNeutral(_ style: NSParagraphStyle) -> Bool {
      let alignmentIsDefault = style.alignment == .left || style.alignment == .natural
      let indentsAreZero =
        style.headIndent == 0 && style.tailIndent == 0 && style.firstLineHeadIndent == 0
      let spacingIsZero =
        style.lineSpacing == 0 && style.paragraphSpacing == 0
        && style.paragraphSpacingBefore == 0 && style.lineHeightMultiple == 0
      let noLists = style.textLists.isEmpty
      let defaultTabs =
        style.tabStops.isEmpty || style.tabStops == NSParagraphStyle.default.tabStops
      return alignmentIsDefault && indentsAreZero && spacingIsZero && noLists && defaultTabs
    }

    private nonisolated static func containsAttachment(_ attributed: NSAttributedString) -> Bool {
      var found = false
      attributed.enumerateAttribute(
        .attachment, in: NSRange(location: 0, length: attributed.length)
      ) { value, _, stop in
        if value != nil {
          found = true
          stop.pointee = true
        }
      }
      return found
    }

    // MARK: Formatting detection

    /// True when any run differs from `defaultAttributes` in font
    /// family/size/traits, underline, strike, foreground color, link, or
    /// attachment.
    public static func hasFormatting(_ attributed: NSAttributedString) -> Bool {
      let defaultFont = defaultAttributes[.font] as? NSFont
      var formatted = false
      let full = NSRange(location: 0, length: attributed.length)
      attributed.enumerateAttributes(in: full) { attrs, _, stop in
        if runDiffersFromDefault(attrs, defaultFont: defaultFont) {
          formatted = true
          stop.pointee = true
        }
      }
      return formatted
    }

    private static func runDiffersFromDefault(
      _ attrs: [NSAttributedString.Key: Any], defaultFont: NSFont?
    ) -> Bool {
      if attrs[.attachment] != nil || attrs[.link] != nil { return true }
      if (attrs[.underlineStyle] as? Int ?? 0) != 0 { return true }
      if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { return true }
      if let font = attrs[.font] as? NSFont, let defaultFont, fontDiffers(font, defaultFont) {
        return true
      }
      if let color = attrs[.foregroundColor] as? NSColor, colorDiffersFromDefault(color) {
        return true
      }
      return false
    }

    private static func fontDiffers(_ a: NSFont, _ b: NSFont) -> Bool {
      let manager = NSFontManager.shared
      return a.familyName != b.familyName || a.pointSize != b.pointSize
        || manager.traits(of: a).intersection(traitMask)
          != manager.traits(of: b).intersection(traitMask)
    }

    private static let traitMask: NSFontTraitMask = [.boldFontMask, .italicFontMask]

    private static func colorDiffersFromDefault(_ color: NSColor) -> Bool {
      guard let base = (defaultAttributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB),
        let other = color.usingColorSpace(.sRGB)
      else { return true }
      return abs(base.redComponent - other.redComponent) > colorTolerance
        || abs(base.greenComponent - other.greenComponent) > colorTolerance
        || abs(base.blueComponent - other.blueComponent) > colorTolerance
        || abs(base.alphaComponent - other.alphaComponent) > colorTolerance
    }

    // MARK: Toggles

    /// Adds `trait` to `range`, or removes it when every character in the
    /// range already has it. Empty / out-of-bounds ranges are clamped; an
    /// empty result is a no-op.
    public static func toggle(
      _ trait: FormatTrait, in storage: NSMutableAttributedString, range: NSRange
    ) {
      let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
      guard clamped.length > 0 else { return }
      let remove = rangeFullyHas(trait, in: storage, range: clamped)
      storage.beginEditing()
      switch trait {
      case .bold: applyFontTrait(.boldFontMask, remove: remove, in: storage, range: clamped)
      case .italic: applyFontTrait(.italicFontMask, remove: remove, in: storage, range: clamped)
      case .underline:
        if remove {
          storage.removeAttribute(.underlineStyle, range: clamped)
        } else {
          storage.addAttribute(
            .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: clamped)
        }
      }
      storage.endEditing()
    }

    /// The traits that are "on" for the editor's current state: every
    /// character of a non-empty `selection` has it, or — with a caret — the
    /// `typingAttributes` do. This is what the toolbar toggles report as
    /// pressed.
    public static func activeTraits(
      in storage: NSAttributedString, selection: NSRange,
      typingAttributes: [NSAttributedString.Key: Any]
    ) -> Set<FormatTrait> {
      let clamped = NSIntersectionRange(selection, NSRange(location: 0, length: storage.length))
      if clamped.length > 0 {
        return Set(FormatTrait.allCases.filter { rangeFullyHas($0, in: storage, range: clamped) })
      }
      return Set(FormatTrait.allCases.filter { hasTrait($0, attributes: typingAttributes) })
    }

    private static func fontTraitMask(_ trait: FormatTrait) -> NSFontTraitMask? {
      switch trait {
      case .bold: return .boldFontMask
      case .italic: return .italicFontMask
      case .underline: return nil
      }
    }

    private static func rangeFullyHas(
      _ trait: FormatTrait, in storage: NSAttributedString, range: NSRange
    ) -> Bool {
      var all = true
      storage.enumerateAttributes(in: range) { attrs, _, stop in
        if !hasTrait(trait, attributes: attrs) {
          all = false
          stop.pointee = true
        }
      }
      return all
    }

    /// Whether text carrying `attributes` has `trait` (a missing font counts
    /// as the editor's default font). Drives the toolbar toggles' pressed
    /// state, so the VoiceOver value tracks the selection / typing style.
    public static func hasTrait(
      _ trait: FormatTrait, attributes attrs: [NSAttributedString.Key: Any]
    ) -> Bool {
      if let mask = fontTraitMask(trait) {
        let font = (attrs[.font] as? NSFont) ?? (defaultAttributes[.font] as? NSFont)
        return font.map { NSFontManager.shared.traits(of: $0).contains(mask) } ?? false
      }
      return (attrs[.underlineStyle] as? Int ?? 0) != 0
    }

    private static func applyFontTrait(
      _ mask: NSFontTraitMask, remove: Bool, in storage: NSMutableAttributedString,
      range: NSRange
    ) {
      let manager = NSFontManager.shared
      storage.enumerateAttribute(.font, in: range) { value, runRange, _ in
        let font = (value as? NSFont) ?? (defaultAttributes[.font] as? NSFont)
        guard let font else { return }
        let converted =
          remove
          ? manager.convert(font, toNotHaveTrait: mask)
          : manager.convert(font, toHaveTrait: mask)
        storage.addAttribute(.font, value: converted, range: runRange)
      }
    }
  }
#endif
