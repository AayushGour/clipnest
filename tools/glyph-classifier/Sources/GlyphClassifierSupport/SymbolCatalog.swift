// SymbolCatalog.swift
//
// T-GLY1: the single source of truth for what this spike's classifier is
// trained to recognize — shared by `GlyphDatasetGen` (renders training/test
// images per class) and `GlyphTrainer` (reads the same class list to report
// per-class-group metrics). One place, per coding-standards.md's "no magic
// strings" rule — neither executable hardcodes its own copy of the class
// list.

/// One keyboard-glyph class. `id` doubles as the training-folder name (must
/// be filesystem- and CreateML-label-safe — plain ASCII, no punctuation
/// SwiftData/CreateML would choke on) and the class label reported in
/// evaluation metrics.
public struct KeyboardGlyph: Sendable {
  public let id: String
  public let character: String
  /// Human-readable name, used only in printed reports — not a training
  /// label.
  public let displayName: String

  public init(id: String, character: String, displayName: String) {
    self.id = id
    self.character = character
    self.displayName = displayName
  }
}

/// One emoji class. `id` is derived from the emoji's hex codepoint(s)
/// (`emoji_1F680` for a single-scalar emoji) rather than the emoji
/// character itself, so training-folder names never depend on a
/// filesystem's handling of combining marks / variation selectors (some
/// chosen emoji carry an explicit U+FE0F to force color-emoji presentation
/// — see `GlyphClassifierSupport.forceEmojiPresentation(_:)`).
public struct EmojiClass: Sendable {
  public let id: String
  public let character: String

  public init(id: String, character: String) {
    self.id = id
    self.character = character
  }
}

/// The label CreateML trains for anything that is neither a keyboard glyph
/// nor a chosen emoji — deliberately the single most heavily populated
/// class in the dataset (see `GlyphDatasetGen`'s `notSymbolSamplesPerRun`)
/// because a false-positive here (real text misread as a glyph/emoji)
/// silently corrupts a user's searchable clipboard text, which is strictly
/// worse than the OCR gap this spike is trying to close. See T-GLY1's task
/// brief in `.claude/logs/senior-dev.md` for the measured gate this class's
/// precision must clear before Phase 2 (T-GLY2) is allowed to start.
public let notSymbolClassID = "notSymbol"

public enum SymbolCatalog {
  /// The 9 keyboard glyphs Vision structurally cannot read (see this
  /// spike's benchmark in the task brief — `.accurate` Vision returns an
  /// empty string or a wrong Latin letter for all of these). Two beyond the
  /// brief's explicit list (⇥ tab, ⇪ capslock) were judged worth adding:
  /// both appear in real keyboard-shortcut text ("⇥ to switch panes",
  /// "⇪ for caps lock") exactly like the other seven, and cost nothing
  /// extra once the renderer/aliasing machinery exists for the rest.
  public static let keyboardGlyphs: [KeyboardGlyph] = [
    KeyboardGlyph(id: "cmd", character: "\u{2318}", displayName: "Command"),
    KeyboardGlyph(id: "opt", character: "\u{2325}", displayName: "Option"),
    KeyboardGlyph(id: "shift", character: "\u{21E7}", displayName: "Shift"),
    KeyboardGlyph(id: "ctrl", character: "\u{2303}", displayName: "Control"),
    KeyboardGlyph(id: "esc", character: "\u{238B}", displayName: "Escape"),
    KeyboardGlyph(id: "enter", character: "\u{23CE}", displayName: "Enter/Return"),
    KeyboardGlyph(id: "delete", character: "\u{232B}", displayName: "Delete/Backspace"),
    KeyboardGlyph(id: "tab", character: "\u{21E5}", displayName: "Tab"),
    KeyboardGlyph(id: "capslock", character: "\u{21EA}", displayName: "Caps Lock"),
  ]

  /// The emoji subset for this spike: 64 single-codepoint (plus, where
  /// needed, an explicit U+FE0F variation selector to force color
  /// presentation — never a ZWJ sequence or a skin-tone modifier) emoji,
  /// spread across 7 common categories. **The cut, stated plainly:** the
  /// full Unicode emoji set (3,000+ base emoji before ZWJ/skin-tone
  /// multiplication) is not attemptable in one spike — every additional
  /// class both multiplies dataset-generation/training time roughly
  /// linearly AND makes CreateML's transfer-learning head's job harder
  /// (more classes to separate from the same small crop, using a feature
  /// extractor never trained on tiny cropped glyphs to begin with). 64 was
  /// chosen as a number large enough to prove the "many small distinct
  /// visual glyphs" case scales past the 9 keyboard glyphs, small enough to
  /// keep this a same-session spike rather than a multi-hour training run.
  /// Selection favored well-known, visually-distinct, frequently-referenced
  /// emoji (the ones a user is actually likely to paste/screenshot) over
  /// exhaustiveness — this is explicitly NOT a frequency-ranked top-64 from
  /// any specific corpus, just a defensible spread a working engineer
  /// recognizes as "the common ones." ZWJ sequences (e.g. 👨‍👩‍👧‍👦) and
  /// skin-tone modifiers (e.g. 👍🏽) are excluded entirely: both multiply
  /// class count for glyphs that are compositions of already-covered base
  /// glyphs, not new distinct shapes worth their own class.
  public static let emojiSubset: [EmojiClass] = {
    let raw: [(String, [UInt32])] = [
      // Smileys / emotion (16)
      ("grinning_face", [0x1F600]), ("face_with_tears_of_joy", [0x1F602]),
      ("grinning_face_with_sweat", [0x1F605]), ("smiling_face_with_smiling_eyes", [0x1F60A]),
      ("smiling_face_with_heart_eyes", [0x1F60D]), ("smiling_face_with_hearts", [0x1F970]),
      ("face_blowing_a_kiss", [0x1F618]), ("smiling_face_with_sunglasses", [0x1F60E]),
      ("thinking_face", [0x1F914]), ("crying_face", [0x1F622]),
      ("loudly_crying_face", [0x1F62D]), ("pouting_face", [0x1F621]),
      ("partying_face", [0x1F973]), ("sleeping_face", [0x1F634]),
      ("face_with_rolling_eyes", [0x1F644]), ("hugging_face", [0x1F917]),
      // Gestures (10)
      ("thumbs_up", [0x1F44D]), ("thumbs_down", [0x1F44E]), ("clapping_hands", [0x1F44F]),
      ("raising_hands", [0x1F64C]), ("folded_hands", [0x1F64F]), ("waving_hand", [0x1F44B]),
      ("flexed_biceps", [0x1F4AA]), ("handshake", [0x1F91D]),
      ("victory_hand", [0x270C, 0xFE0F]), ("crossed_fingers", [0x1F91E]),
      // Hearts (4)
      ("red_heart", [0x2764, 0xFE0F]), ("broken_heart", [0x1F494]),
      ("two_hearts", [0x1F495]), ("hundred_points", [0x1F4AF]),
      // Animals / nature (10)
      ("dog_face", [0x1F436]), ("cat_face", [0x1F431]), ("panda_face", [0x1F43C]),
      ("lion_face", [0x1F981]), ("cherry_blossom", [0x1F338]), ("rainbow", [0x1F308]),
      ("star", [0x2B50]), ("fire", [0x1F525]), ("water_wave", [0x1F30A]),
      ("crescent_moon", [0x1F319]),
      // Food (8)
      ("pizza", [0x1F355]), ("hamburger", [0x1F354]), ("red_apple", [0x1F34E]),
      ("beer_mug", [0x1F37A]), ("hot_beverage", [0x2615]), ("doughnut", [0x1F369]),
      ("soft_ice_cream", [0x1F366]), ("birthday_cake", [0x1F382]),
      // Travel (6)
      ("rocket", [0x1F680]), ("airplane", [0x2708, 0xFE0F]), ("automobile", [0x1F697]),
      ("house", [0x1F3E0]), ("globe_showing_americas", [0x1F30E]),
      ("statue_of_liberty", [0x1F5FD]),
      // Objects / symbols (10)
      ("party_popper", [0x1F389]), ("wrapped_gift", [0x1F381]), ("musical_note", [0x1F3B5]),
      ("camera", [0x1F4F7]), ("light_bulb", [0x1F4A1]), ("key", [0x1F511]),
      ("alarm_clock", [0x23F0]), ("mobile_phone", [0x1F4F1]), ("laptop", [0x1F4BB]),
      ("check_mark_button", [0x2705]),
    ]
    return raw.map { name, scalars in
      // Force color-emoji presentation uniformly by appending U+FE0F
      // (VARIATION SELECTOR-16) to every entry that doesn't already end in
      // one, rather than hand-picking which of the 64 need it. Several
      // codepoints in the Miscellaneous Symbols / Dingbats blocks
      // (U+2600-27BF, e.g. victory_hand/red_heart/airplane above) default
      // to monochrome TEXT presentation without it — appending VS16 is a
      // documented no-op for codepoints that are already
      // Emoji_Presentation=Yes (the vast majority here, U+1F300+), so this
      // is safe to do unconditionally rather than needing a per-codepoint
      // presentation-default lookup table.
      let forcedScalars = scalars.last == 0xFE0F ? scalars : scalars + [0xFE0F]
      let hexID =
        "emoji_" + scalars.map { String($0, radix: 16, uppercase: true) }.joined(separator: "_")
      let character = String(
        String.UnicodeScalarView(forcedScalars.compactMap(Unicode.Scalar.init)))
      return EmojiClass(id: hexID, character: character)
    }
  }()

  /// Printable ASCII notSymbol seed alphabet: upper/lowercase Latin,
  /// digits, and common punctuation. Deliberately includes every character
  /// this spike's Vision benchmark actually misread a glyph as (H, T, 4,
  /// ^, plus the task brief's other named confusables x/X/g/s) — those are
  /// not just "in the alphabet somewhere," they get oversampled by
  /// `GlyphDatasetGen` specifically (see `confusableCharacters`).
  public static let asciiAlphabet: [String] =
    (65...90).map { String(Unicode.Scalar($0)!) }  // A-Z
    + (97...122).map { String(Unicode.Scalar($0)!) }  // a-z
    + (48...57).map { String(Unicode.Scalar($0)!) }  // 0-9
    + Array("!@#$%^&*()-_=+[]{};:'\",.<>/?\\|`~ ").map(String.init)

  /// The characters this spike's own Vision benchmark actually produced as
  /// misreads of ⌘/⌥/⇧/⌃ (H/#, T, 4, ^), plus the task brief's other named
  /// confusables (x, X, g, s) — oversampled in `notSymbol` generation
  /// because these are exactly the characters a false positive would most
  /// plausibly claim to be a keyboard glyph.
  public static let confusableCharacters: [String] = ["H", "#", "T", "4", "^", "x", "X", "g", "s"]

  /// Small pool of arbitrary short words, used by `GlyphDatasetGen` to
  /// render partial-character crops (a random sub-window of real running
  /// text) for `notSymbol` — real Vision bounding boxes are not tight, so
  /// some of the crops the production classifier will actually see are a
  /// fragment of a real word, not one full character centered in its box.
  public static let arbitraryWords: [String] = [
    "Settings", "Preferences", "Clipboard", "History", "Search", "Paste", "Copy",
    "Window", "Finder", "Terminal", "Safari", "Message", "Notes", "Reminder",
    "hello world", "the quick brown fox", "user@example.com", "https://example.com",
    "Total: $42.50", "2026-09-03", "v1.2.3", "TODO: fix this", "Error 404",
    "function main()", "let x = 10", "git commit -m", "npm install", "swift test",
  ]
}
