// ShortcutHints.swift
//
// T-SET2 (regression fix): `PickerView.shortcutHints` used to build its
// string directly, inline, as a `private var` on the View — but that made
// it untestable (Swift's `private` access means it can't be reached even
// via `@testable import`, and instantiating a full `PickerView` just to
// read one `String` would drag in `PickerViewModel`/AppKit hosting).
// Pulled the pure, no-SwiftUI-dependency part out here — same pattern as
// `WindowPlacement.swift` (pure `CGRect`/`CGPoint` math extracted from
// `PickerPanel`/`ItemPreviewController` for the same reason, see that
// file's top doc comment) — so it can be unit tested directly.
//
// This fixes the truncation regression: the footer used to always spell
// out "⌥⏎ plain/OCR text" (added by T-OCR2), which overflowed the picker
// panel's fixed width and cut `esc close` off the tail entirely. ⌥⏎ only
// ever pastes OCR text when the highlighted row actually has some (see
// `PickerViewModel+Paste.pasteContent(for:plainText:)`), so the hint is
// contextual instead: "⌥⏎ OCR text" only while such a row is highlighted,
// "⌥⏎ plain" (the original, pre-T-OCR2 wording) otherwise.
//
// That alone still wasn't enough at every state: measured against the
// picker panel's real, source-verified width (`PickerPanel.defaultSize` =
// 560pt — NOT the ~452pt first assumed; see this task's handoff for how
// that was confirmed) via `NSHostingView(rootView: Text(...).font(
// .caption2)).fittingSize`, the available width for the hint text itself
// (panel width minus the footer's own padding, the trailing `Spacer`'s
// minLength, and the version label — worst case ~493pt when the
// update-available dot is showing) was still exceeded on the Snippets tab
// (up to 540pt) and on History/Pinned whenever an OCR-bearing row is
// highlighted (510pt). `esc close` was dropped (see `text(for:tab:
// capabilities:)` below) as the next lever, per the ticket's own
// suggestion: it's the least informative item on the bar (Esc-to-close is
// a near-universal, already-discoverable convention) and reclaiming its
// text + separator (~56-57pt) is enough on its own — re-measured, every
// tab/OCR-state combination now fits with a positive margin (worst case at
// the time: Snippets tab, OCR-bearing row highlighted, update dot showing —
// 484pt against 493pt available, +9pt margin). Do not re-add `esc close`
// without re-running this same measurement — the budget is tight enough
// that any further growth elsewhere in the bar (a longer version string, a
// new shortcut) needs the same width check.
//
// T-SET4 (user bug report: ⌘S popped the save-as-snippet form for a
// highlighted `.image` row, which the row's own UI never offers — the key
// handler, the row, and this footer had three independently-drifted copies
// of "which kinds does this apply to"): re-audited every hint against the
// real per-kind/per-tab implementations (`PickerViewModel
// .pasteContent(for:plainText:)`, `pasteSnippet(_:)`, `handle(_:)`'s key
// switch, `togglePinHighlighted`, `presentSaveAsSnippetForm(from:)`). Two
// corrections came out of that audit, both folded into
// `HighlightedItemCapabilities` below so `text(for:tab:capabilities:)` stays
// a single pure function driven by one small value type instead of a
// growing pile of `Bool` parameters (readable call sites, and exhaustive
// per-field coverage in tests):
//
// 1. `⌘S save` was shown unconditionally on History/Pinned, regardless of
//    the highlighted row's kind — exactly the reported bug. Now gated on
//    `ClipItem.supportsSaveAsSnippet` (Core, shared with `ItemRow`'s own
//    button/context-menu gating and `PickerViewModel`'s actual ⌘S handler —
//    see that property's doc comment), so it only shows for `.text`/`.link`.
//
// 2. ⌥⏎ is advertised more narrowly than the original hypothesis for this
//    task assumed. Tracing `pasteContent(for:plainText:)` kind-by-kind: for
//    `.text`/`.link`, the `plainText: true` branch returns the exact same
//    `.text(item.previewText)` the non-plain branch already returns for
//    those kinds (there's no richer stored form to strip — confirmed by
//    `PasteboardReader.readPlainText`, which never sets a `blobPath` for
//    either kind, and by `PickerViewModelPasteContentTests`'s existing
//    "ignores plainText — there's no richer form to strip" cases for both).
//    So ⌥⏎ is observably IDENTICAL to ⏎ for `.text`/`.link`, on top of the
//    already-known `.file`/OCR-less-`.image` cases — the same "advertising
//    it is a lie" reasoning this task's brief already applied to those two
//    extends to `.text`/`.link` too. ⌥⏎ genuinely differs from ⏎ only for
//    `.richText` (strips to plain, vs. pasting the stored RTF) and `.image`
//    *with* recognized text (pastes that text, vs. the image itself) — see
//    `AltEnterHint`'s doc comment. Also newly covered: the Snippets tab
//    (`pasteSnippet(_:)` ignores `plainText` entirely — same "identical to
//    ⏎" reasoning) and the no-highlighted-row state (nothing to act on) —
//    both now correctly omit ⌥⏎ instead of defaulting to "⌥⏎ plain".
//
// Width re-check (both corrections only ever REMOVE hint text — `⌘S save`
// now sometimes absent, ⌥⏎ now absent for more kinds — so every state's
// width only shrank; re-measured the same way as the T-SET2 rounds above
// (`NSHostingView(rootView: Text(...).font(.caption2)).fittingSize`) to
// confirm rather than assume): worst case is now the Snippets tab at 408pt
// (down from 484pt) against the same 493pt-with-update-dot budget — +85pt
// margin, vs. the +9pt this file's T-SET2-round-2 fix left. History/Pinned's
// widest state (an OCR-bearing `.image` highlighted, 404pt) has +89pt.
//
// T-SET5 (⌘, opens Settings — user bug report "cmd+, isn't working"): adds
// "⌘, settings" as the final, tab-independent hint (it's a picker-wide
// action, not scoped to History/Pinned vs. Snippets, so it's appended after
// `⌘1/2/3 tabs` for every tab/capability state rather than folded into the
// tab-specific groups). Re-measured the same way as every round above —
// this is the first change since the T-SET2-round-2 fix to ADD text rather
// than only remove it, so the margin genuinely shrinks (not just
// "recompute to confirm it didn't"): worst case is Snippets at 473pt (up
// from 408pt) against the unchanged 493pt budget — +20pt margin. The
// tightest History/Pinned state (an OCR-bearing `.image` highlighted, 469pt)
// has +24pt. Both positive; the hint was added. A future addition anywhere
// in this bar needs the same re-measurement — the margin is real but no
// longer the +85/+89pt this file's T-SET4 round left.
//
// Linux Delete parity fix: `KeyEventMapping.swift`'s `Keyval.delete` case
// used to require Ctrl (an inconsistency with no platform reason — macOS's
// own `.delete` case has always matched bare Delete unconditionally). Now
// that bare Delete works on Linux too, `ShortcutModifierVocabulary
// .platformDefault`'s Linux `delete` hint changed from `"Ctrl+Delete
// delete"` to `"Delete delete"` — see that property's own doc comment
// below for why Ctrl+Delete (still accepted, just no longer advertised)
// isn't listed as a second alias. Text-length-only change (19 chars ->
// 13), so it can only shrink this footer's total width, never grow it — no
// re-measurement against the width budget above is needed (that budget is
// macOS-only in the first place; this file's Linux branch renders in
// `ClipnestGTK`'s own window, not `PickerPanel`'s fixed-width one).
//
// Keyboard-parity pass (routed follow-up): closes the last real gap between
// the two platforms' footers — `save`/`newSnippet`/`replaceSnippet`/
// `settings` were `nil` on Linux because `KeyEventMapping.swift` had no
// Ctrl+S/Ctrl+N/Ctrl+Shift+E/Ctrl+, binding at all (see `PickerKeyAction
// .swift`'s top doc comment for the full inventory: each already had a
// working `PickerViewModel` method reachable only by mouse, or — for
// "settings" — only via the tray/D-Bus menu). Now that
// `KeyEventMapping.action(keyval:state:)` binds all four, this vocabulary
// names them, in the same terse "Ctrl+X action" style every other Linux
// entry already uses (no spaces around `+`, matching `Ctrl+1/2/3`). As with
// the Delete fix above, this file's Linux branch has no fixed-width budget
// to re-measure against.
import ClipnestCore
import Foundation

/// What the picker footer's contextual hints (`⌥⏎`, `⌘S`) should say about
/// the row currently highlighted on History/Pinned — `nil`/`false` on the
/// Snippets tab and whenever nothing is highlighted, since neither hint's
/// underlying action differs from `⏎`/does anything there (see
/// `ShortcutHints.swift`'s top T-SET4 doc comment). A small value type
/// rather than a growing list of `Bool` parameters to `text(for:tab:
/// capabilities:)` — one place per hint's decision, and one thing for a
/// test to construct/assert against per case, instead of positional Bools
/// that are easy to transpose.
public struct HighlightedItemCapabilities: Equatable, Sendable {
  /// Which wording ⌥⏎ should use — `nil` when ⌥⏎ would paste exactly what
  /// `⏎` already pastes for the highlighted row, in which case advertising
  /// it would be misleading (see `ShortcutHints.swift`'s top doc comment).
  enum AltEnterHint: Equatable {
    /// `.richText`: strips the stored rich (RTF) form down to plain text.
    case plain
    /// `.image` with on-device-recognized text: pastes that text instead
    /// of the image.
    case ocrText
  }

  let altEnterHint: AltEnterHint?
  /// Mirrors `ClipItem.supportsSaveAsSnippet` — whether `⌘S` does anything
  /// for the highlighted row.
  let supportsSaveAsSnippet: Bool

  /// - Parameter item: the currently-highlighted `ClipItem`, or `nil` when
  ///   nothing is highlighted (an empty list) OR the active tab is
  ///   Snippets (a `Snippet` isn't a `ClipItem`, and neither hint's action
  ///   varies by which snippet is highlighted — see this file's top doc
  ///   comment).
  init(item: ClipItem?) {
    guard let item else {
      altEnterHint = nil
      supportsSaveAsSnippet = false
      return
    }
    switch item.kind {
    case .richText:
      altEnterHint = .plain
    case .image where item.hasRecognizedText:
      altEnterHint = .ocrText
    case .image, .text, .link, .file:
      altEnterHint = nil
    }
    supportsSaveAsSnippet = item.supportsSaveAsSnippet
  }
}

// T-BUG2 (parity-audit bug #2): the footer used to hardcode macOS glyphs
// unconditionally — `Sources/ClipnestGTK/Window/PickerWindow+Reconcile.swift`
// (out of this file's scope) calls this SAME `ShortcutHints.text(for:
// capabilities:)` to build the GTK picker's own footer label, so Linux users
// were shown "⌘F search · ⌘P pin · ⌘S save · ⌘⌫ delete · ⌘1/2/3 tabs · ⌘,
// settings" verbatim — Mac glyphs for chords that don't exist there at all
// (Linux's real bindings are Ctrl-based, per `KeyEventMapping.swift`, which
// has NO binding whatsoever for save/new-snippet/replace-snippet/settings).
// `ShortcutModifierVocabulary` below parameterizes every rendered chord so
// each platform advertises only its own true bindings; `text(for:
// capabilities:vocabulary:)`'s `vocabulary` parameter defaults to
// `.platformDefault`, which resolves via `#if os(macOS)` INSIDE THIS FILE
// (compiled once per platform, like every other `#if os(macOS)` in this
// codebase) — so neither `PickerView.swift`'s macOS call site nor
// `PickerWindow+Reconcile.swift`'s Linux call site needs to change AT ALL;
// each keeps calling `text(for:capabilities:)` exactly as before and
// automatically gets its own platform's real chords.
//
// Content-level reuse only, not an `import`: the task's own brief points at
// `Sources/ClipnestGTK/Support/LinuxShortcutDescriptions.swift` as the
// existing source of Linux combo strings, and the wording below is
// deliberately kept identical to its entries — but `ShortcutHints.swift`
// lives in `ClipnestViewModels`, which `ClipnestGTK` DEPENDS ON (see
// `Package.swift`); `ClipnestViewModels` importing `ClipnestGTK` back would
// be a circular module dependency and simply fail to build. There is
// currently no lower shared module both `ClipnestGTK`'s Settings-tab
// display and this footer can both import for a single source of truth,
// and creating one would mean relocating `LinuxShortcutDescriptions.swift`
// itself — a file owned by a different task/agent, out of this one's
// scope. Flagged here (and in this task's decision log) as a known,
// bounded duplication rather than a silent one: `ShortcutHintsTests.swift`
// pins the exact Linux strings below, so any future rebind that updates
// `LinuxShortcutDescriptions` without updating this file fails a test
// instead of drifting unnoticed.
/// The set of rendered chord strings `ShortcutHints.text(for:capabilities:)`
/// composes its footer from — one platform's true key bindings. A
/// capability whose chord doesn't exist on a platform at all (e.g. Linux's
/// `KeyEventMapping` has no save/new-snippet/replace-snippet/settings
/// binding) is `nil`, which `text(for:capabilities:vocabulary:)` omits
/// entirely rather than rendering a nonexistent shortcut.
public struct ShortcutModifierVocabulary: Sendable {
  let move: String
  let paste: String
  let altEnterPlain: String
  let altEnterOCRText: String
  let search: String
  let pin: String
  let save: String?
  let delete: String
  let newSnippet: String?
  let replaceSnippet: String?
  let tabs: String
  let settings: String?
}

extension ShortcutModifierVocabulary {
  #if os(macOS)
    /// macOS's real bindings — byte-identical to this file's pre-T-BUG2
    /// hardcoded strings; `ShortcutHintsTests.swift`'s exact-string
    /// assertions are the guard.
    public static let platformDefault = ShortcutModifierVocabulary(
      move: "↑↓ move",
      paste: "⏎ paste",
      altEnterPlain: "⌥⏎ plain",
      altEnterOCRText: "⌥⏎ OCR text",
      search: "⌘F search",
      pin: "⌘P pin",
      save: "⌘S save",
      delete: "⌘⌫ delete",
      newSnippet: "⌘N new",
      replaceSnippet: "⌥⌘E replace",
      tabs: "⌘1/2/3 tabs",
      settings: "⌘, settings"
    )
  #else
    /// Linux's real bindings, per `KeyEventMapping.swift` (the single
    /// source of truth for what a key press actually DOES) — wording kept
    /// identical to `LinuxShortcutDescriptions.all`'s combo strings for the
    /// chords it also lists (compacted, no spaces around "/", matching this
    /// footer's own terse style — e.g. `Ctrl+1/2/3` not `Ctrl+1 / 2 / 3`).
    /// Keyboard-parity pass (routed follow-up): `save`/`newSnippet`/
    /// `replaceSnippet`/`settings` used to be `nil` — Linux had no ⌘S/⌘N/
    /// ⌥⌘E/⌘, equivalent bound at all, so this footer correctly didn't
    /// advertise them (that was exactly the T-BUG2 bug this file's doc
    /// comment above describes). `KeyEventMapping.swift` now binds all four
    /// as Ctrl-chords (`Ctrl+S`/`Ctrl+N`/`Ctrl+Shift+E`/`Ctrl+,` — see that
    /// file's top doc comment), so this vocabulary is updated to match —
    /// the same "advertise only what's actually bound" rule that made them
    /// `nil` before now requires naming them.
    ///
    /// `delete: "Delete delete"` (not "Ctrl+Delete delete"): `KeyEventMapping
    /// .action(keyval:state:)`'s `Keyval.delete` case now matches bare
    /// Delete regardless of modifiers (parity fix — it used to require
    /// Ctrl, an inconsistency with macOS with no platform reason behind
    /// it). Ctrl+Delete is still ALSO accepted (kept as an alias, not
    /// dropped, for anyone who already learned it), but the footer
    /// advertises only the simpler, canonical form actually bound — the
    /// same "one hint per action, not a list of every accepted alias"
    /// precedent macOS's own `delete: "⌘⌫ delete"` already sets one line
    /// up: mac's `.delete` case *also* matches bare Delete unconditionally
    /// (see `PickerView.handle(_:)`'s own doc comment), yet the mac hint
    /// only ever names ⌘⌫, its own platform's conventional chord for
    /// deleting a list item — Linux's convention is the bare key itself, so
    /// that's what this hint names.
    public static let platformDefault = ShortcutModifierVocabulary(
      move: "↑/↓ move",
      paste: "Enter paste",
      altEnterPlain: "Alt+Enter plain",
      altEnterOCRText: "Alt+Enter OCR text",
      search: "Ctrl+F search",
      pin: "Ctrl+P pin",
      save: "Ctrl+S save",
      delete: "Delete delete",
      newSnippet: "Ctrl+N new",
      replaceSnippet: "Ctrl+Shift+E replace",
      tabs: "Ctrl+1/2/3 tabs",
      settings: "Ctrl+, settings"
    )
  #endif
}

public enum ShortcutHints {
  /// Builds the picker footer's tab-aware shortcut-hint string.
  ///
  /// - Parameters:
  ///   - tab: the active `PickerTab` — History/Pinned share one shortcut
  ///     group (`⌘P pin`/`⌘S save`), Snippets a different one (`⌘N new`/
  ///     `⌥⌘E replace`); everything else is identical across tabs.
  ///   - capabilities: what the highlighted row supports — see
  ///     `HighlightedItemCapabilities`. Selects ⌥⏎'s wording (or omits it)
  ///     and whether `⌘S save` appears at all.
  ///   - vocabulary: which platform's real chords to render — see
  ///     `ShortcutModifierVocabulary`. Defaults to `.platformDefault`
  ///     (resolved per-platform at THIS file's own compile time), so
  ///     neither macOS's `PickerView` nor Linux's `PickerWindow+Reconcile`
  ///     call site needs to pass this explicitly or change at all (T-BUG2).
  ///
  /// Deliberately omits an `esc close` hint (see this file's top doc
  /// comment for the width budget that forced it) — Esc-to-close remains
  /// fully functional (`PickerView`'s `.onKeyPress(.escape)`), it's just no
  /// longer spelled out in the footer.
  ///
  /// T-SET5: `⌘, settings` is appended last, for every tab/capability state
  /// on platforms that have it (`vocabulary.settings != nil`) — it's a
  /// picker-wide action, not scoped to any one tab's own group, so it sits
  /// outside the `switch tab` below rather than being duplicated into both
  /// branches.
  public static func text(
    for tab: PickerTab,
    capabilities: HighlightedItemCapabilities,
    vocabulary: ShortcutModifierVocabulary = .platformDefault
  ) -> String {
    var parts = [vocabulary.move, vocabulary.paste]
    switch capabilities.altEnterHint {
    case .plain:
      parts.append(vocabulary.altEnterPlain)
    case .ocrText:
      parts.append(vocabulary.altEnterOCRText)
    case nil:
      break
    }
    parts.append(vocabulary.search)
    switch tab {
    case .history, .pinned:
      parts.append(vocabulary.pin)
      if capabilities.supportsSaveAsSnippet, let save = vocabulary.save {
        parts.append(save)
      }
      parts.append(vocabulary.delete)
    case .snippets:
      if let newSnippet = vocabulary.newSnippet {
        parts.append(newSnippet)
      }
      if let replaceSnippet = vocabulary.replaceSnippet {
        parts.append(replaceSnippet)
      }
      parts.append(vocabulary.delete)
    }
    parts.append(vocabulary.tabs)
    if let settings = vocabulary.settings {
      parts.append(settings)
    }
    return parts.joined(separator: " · ")
  }
}
