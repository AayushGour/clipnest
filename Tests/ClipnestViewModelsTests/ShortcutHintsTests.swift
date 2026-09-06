// ShortcutHintsTests.swift
//
// `ShortcutHints.text(for:capabilities:)` and `HighlightedItemCapabilities`
// are both pure, zero-SwiftUI-dependency logic (see `ShortcutHints.swift`'s
// top doc comment) — same shape as `WindowPlacementTests.swift`'s coverage
// of `WindowPlacement`.
//
// T-SET2: covers both branches of the OCR case and both tab variants — the
// truncation-regression matrix.
//
// T-SET2 round 2: also locks down that `esc close` never comes back as a
// literal substring — it was dropped as the width-budget lever (see
// `ShortcutHints.swift`'s top doc comment for the measured numbers); a
// future edit re-adding it without re-checking the width budget would
// silently reintroduce the truncation this suite exists to prevent.
//
// T-SET4 (user bug report — ⌘S popped a save-as-snippet form for a
// highlighted `.image` row): widens coverage from a single `hasRecognizedText:
// Bool` to `HighlightedItemCapabilities`'s full per-kind matrix
// (`ItemKindCapabilityTests`, below) and adds `⌘S save`'s presence/absence
// to every tab × capability-state combination (`ShortcutHintsMatrixTests`),
// the exact gap that let the reported bug ship — the old suite only ever
// varied `hasRecognizedText`, never the ⌘S/save axis.

import ClipnestCore
import Testing

// The `ClipnestApp` target's actual Swift module name is `Clipnest` (see
// `PRODUCT_NAME` in `project.yml`) — see `ItemKind+SFSymbolTests.swift`'s
// top doc comment for the full explanation.
@testable import ClipnestViewModels

// MARK: - HighlightedItemCapabilities(item:) — the per-kind/OCR-state truth
// table T-SET4's audit established (see `ShortcutHints.swift`'s top doc
// comment for the reasoning behind each row).

@Suite("HighlightedItemCapabilities")
struct ItemKindCapabilityTests {

  @Test(".text: ⌥⏎ omitted (identical to ⏎), ⌘S supported")
  func text() {
    let capabilities = HighlightedItemCapabilities(item: makeClipItem(kind: .text))
    #expect(capabilities.altEnterHint == nil)
    #expect(capabilities.supportsSaveAsSnippet)
  }

  @Test(".link: ⌥⏎ omitted (identical to ⏎), ⌘S supported")
  func link() {
    let capabilities = HighlightedItemCapabilities(item: makeClipItem(kind: .link))
    #expect(capabilities.altEnterHint == nil)
    #expect(capabilities.supportsSaveAsSnippet)
  }

  @Test(".richText: ⌥⏎ plain (genuinely strips to plain text), ⌘S not supported")
  func richText() {
    let capabilities = HighlightedItemCapabilities(item: makeClipItem(kind: .richText))
    #expect(capabilities.altEnterHint == .plain)
    #expect(!capabilities.supportsSaveAsSnippet)
  }

  @Test(".image without recognized text: ⌥⏎ omitted (identical to ⏎), ⌘S not supported")
  func imageWithoutOCR() {
    let capabilities = HighlightedItemCapabilities(
      item: makeClipItem(kind: .image, ocrText: nil))
    #expect(capabilities.altEnterHint == nil)
    #expect(!capabilities.supportsSaveAsSnippet)
  }

  @Test("`.image` with empty-string recognized text: still ⌥⏎ omitted")
  func imageWithEmptyOCR() {
    let capabilities = HighlightedItemCapabilities(
      item: makeClipItem(kind: .image, ocrText: ""))
    #expect(capabilities.altEnterHint == nil)
  }

  @Test(".image with recognized text: ⌥⏎ OCR text, ⌘S not supported")
  func imageWithOCR() {
    let capabilities = HighlightedItemCapabilities(
      item: makeClipItem(kind: .image, ocrText: "Invoice #4471"))
    #expect(capabilities.altEnterHint == .ocrText)
    #expect(!capabilities.supportsSaveAsSnippet)
  }

  @Test(".file: ⌥⏎ omitted (has no plain form at all), ⌘S not supported")
  func file() {
    let capabilities = HighlightedItemCapabilities(
      item: makeClipItem(kind: .file, fileReference: "file:///tmp/report.pdf"))
    #expect(capabilities.altEnterHint == nil)
    #expect(!capabilities.supportsSaveAsSnippet)
  }

  @Test("nil (nothing highlighted, or Snippets tab): ⌥⏎ omitted, ⌘S not supported")
  func nilItem() {
    let capabilities = HighlightedItemCapabilities(item: nil)
    #expect(capabilities.altEnterHint == nil)
    #expect(!capabilities.supportsSaveAsSnippet)
  }

  @Test("Every ItemKind is covered — exhaustiveness guard")
  func everyKindCovered() {
    for kind in ItemKind.allCases {
      // Must not crash/trap for any kind — the real assertion is compiling:
      // `HighlightedItemCapabilities.init`'s switch over `item.kind` is
      // exhaustive, so a new `ItemKind` case would fail to build this file
      // long before this test could run.
      _ = HighlightedItemCapabilities(item: makeClipItem(kind: kind))
    }
    #expect(ItemKind.allCases.count == 5)
  }
}

// MARK: - ShortcutHints.text(for:capabilities:) — full tab × capability
// matrix
//
// T-BUG2 (parity-audit bug #2): `ShortcutHints.text(for:capabilities:)` now
// renders a platform-specific `ShortcutModifierVocabulary` (defaulted, so
// this suite's existing calls are unaffected) — see `ShortcutHints.swift`'s
// top doc comment. The suite below is macOS-only from here on: it asserts
// the EXACT macOS glyphs verbatim, unchanged from before T-BUG2 (the
// "macOS output must be byte-identical" requirement), which would now
// legitimately FAIL if run on Linux post-fix (Linux correctly renders
// Ctrl-based chords instead — that's the bug being fixed, not a
// regression). `LinuxShortcutHintsMatrixTests` below is the Linux
// equivalent, same shape, real Linux wording.
#if os(macOS)
  @Suite("ShortcutHints.text matrix")
  struct ShortcutHintsMatrixTests {

    /// One row per `HighlightedItemCapabilities` state this task's audit
    /// distinguishes — mirrors `ItemKindCapabilityTests` above so a footer
    /// string is checked for every state that struct can produce.
    private static let capabilityCases:
      [(name: String, capabilities: HighlightedItemCapabilities)] =
        [
          ("text/link (no ⌥⏎, ⌘S)", HighlightedItemCapabilities(item: makeClipItem(kind: .text))),
          (
            "richText (⌥⏎ plain, no ⌘S)",
            HighlightedItemCapabilities(item: makeClipItem(kind: .richText))
          ),
          (
            "image w/o OCR (no ⌥⏎, no ⌘S)",
            HighlightedItemCapabilities(item: makeClipItem(kind: .image, ocrText: nil))
          ),
          (
            "image w/ OCR (⌥⏎ OCR text, no ⌘S)",
            HighlightedItemCapabilities(item: makeClipItem(kind: .image, ocrText: "text"))
          ),
          (
            "file (no ⌥⏎, no ⌘S)",
            HighlightedItemCapabilities(
              item: makeClipItem(kind: .file, fileReference: "file:///tmp/x"))
          ),
          ("nil / nothing highlighted (no ⌥⏎, no ⌘S)", HighlightedItemCapabilities(item: nil)),
        ]

    @Test(
      "Every tab × capability-state combination: ⌥⏎ wording and ⌘S presence match the capability",
      arguments: PickerTab.allCases, Self.capabilityCases)
    func matchesCapability(
      tab: PickerTab, testCase: (name: String, capabilities: HighlightedItemCapabilities)
    ) {
      let hints = ShortcutHints.text(for: tab, capabilities: testCase.capabilities)

      switch testCase.capabilities.altEnterHint {
      case .plain:
        #expect(hints.contains("⌥⏎ plain"))
        #expect(!hints.contains("OCR text"))
      case .ocrText:
        #expect(hints.contains("⌥⏎ OCR text"))
        #expect(!hints.contains("⌥⏎ plain"))
      case nil:
        #expect(!hints.contains("⌥⏎"))
      }

      switch tab {
      case .history, .pinned:
        if testCase.capabilities.supportsSaveAsSnippet {
          #expect(hints.contains("⌘S save"))
        } else {
          #expect(!hints.contains("⌘S save"), "no-supporting-kind row must not advertise ⌘S save")
        }
      case .snippets:
        // ⌘S isn't part of the Snippets group at all, regardless of
        // `supportsSaveAsSnippet` (irrelevant there — see `ShortcutHints
        // .swift`'s top doc comment).
        #expect(!hints.contains("⌘S save"))
      }
    }

    // MARK: - Never regress to the permanently-overloaded pre-fix wording

    @Test("The permanently-spelled-out regression wording never appears, any tab/capability")
    func neverProducesPermanentlyOverloadedWording() {
      for tab in PickerTab.allCases {
        for testCase in Self.capabilityCases {
          let hints = ShortcutHints.text(for: tab, capabilities: testCase.capabilities)
          #expect(!hints.contains("plain/OCR text"))
        }
      }
    }

    // MARK: - `esc close` stays dropped (the width-budget lever, round 2)

    @Test("`esc close` never appears — dropped as the width-budget lever, every tab/capability")
    func neverContainsEscClose() {
      for tab in PickerTab.allCases {
        for testCase in Self.capabilityCases {
          let hints = ShortcutHints.text(for: tab, capabilities: testCase.capabilities)
          #expect(!hints.contains("esc close"))
        }
      }
    }

    // MARK: - Every tab/capability still ends with the tabs hint, unclipped

    @Test("Every tab × capability combination ends with '⌘1/2/3 tabs · ⌘, settings'")
    func everyCombinationEndsWithTabs() {
      for tab in PickerTab.allCases {
        for testCase in Self.capabilityCases {
          let hints = ShortcutHints.text(for: tab, capabilities: testCase.capabilities)
          #expect(hints.hasSuffix("⌘1/2/3 tabs · ⌘, settings"))
        }
      }
    }

    // MARK: - T-SET5: `⌘, settings` appears for every tab/capability state

    @Test("`⌘, settings` appears exactly once, every tab/capability combination")
    func everyCombinationContainsSettingsHint() {
      for tab in PickerTab.allCases {
        for testCase in Self.capabilityCases {
          let hints = ShortcutHints.text(for: tab, capabilities: testCase.capabilities)
          #expect(hints.contains("⌘, settings"))
        }
      }
    }

    // MARK: - Full string, exact match for the canonical states (locks down
    // ordering + content, same style the original T-SET2 suite used)

    @Test("History tab, exact hint string for text/link (no ⌥⏎, ⌘S shown)")
    func historyTextExact() {
      #expect(
        ShortcutHints.text(
          for: .history,
          capabilities: HighlightedItemCapabilities(item: makeClipItem(kind: .text)))
          == "↑↓ move · ⏎ paste · ⌘F search · ⌘P pin · ⌘S save · ⌘⌫ delete · ⌘1/2/3 tabs · ⌘, settings"
      )
    }

    @Test("History tab, exact hint string for .richText (⌥⏎ plain, ⌘S hidden)")
    func historyRichTextExact() {
      #expect(
        ShortcutHints.text(
          for: .history,
          capabilities: HighlightedItemCapabilities(item: makeClipItem(kind: .richText)))
          == "↑↓ move · ⏎ paste · ⌥⏎ plain · ⌘F search · ⌘P pin · ⌘⌫ delete · ⌘1/2/3 tabs · ⌘, settings"
      )
    }

    @Test("History tab, exact hint string for OCR-bearing .image (⌥⏎ OCR text, ⌘S hidden)")
    func historyImageOCRExact() {
      #expect(
        ShortcutHints.text(
          for: .history,
          capabilities: HighlightedItemCapabilities(
            item: makeClipItem(kind: .image, ocrText: "text")))
          == "↑↓ move · ⏎ paste · ⌥⏎ OCR text · ⌘F search · ⌘P pin · ⌘⌫ delete · ⌘1/2/3 tabs · ⌘, settings"
      )
    }

    @Test("History tab, exact hint string for .file (no ⌥⏎, ⌘S hidden)")
    func historyFileExact() {
      #expect(
        ShortcutHints.text(
          for: .history,
          capabilities: HighlightedItemCapabilities(
            item: makeClipItem(kind: .file, fileReference: "file:///tmp/x")))
          == "↑↓ move · ⏎ paste · ⌘F search · ⌘P pin · ⌘⌫ delete · ⌘1/2/3 tabs · ⌘, settings"
      )
    }

    @Test("Pinned tab mirrors History for every capability state")
    func pinnedMirrorsHistory() {
      for testCase in Self.capabilityCases {
        #expect(
          ShortcutHints.text(for: .pinned, capabilities: testCase.capabilities)
            == ShortcutHints.text(for: .history, capabilities: testCase.capabilities))
      }
    }

    @Test("Snippets tab, exact hint string (no ⌥⏎, no ⌘S, ⌘N/⌥⌘E group)")
    func snippetsExact() {
      #expect(
        ShortcutHints.text(for: .snippets, capabilities: HighlightedItemCapabilities(item: nil))
          == "↑↓ move · ⏎ paste · ⌘F search · ⌘N new · ⌥⌘E replace · ⌘⌫ delete · ⌘1/2/3 tabs · ⌘, settings"
      )
    }
  }
#else
  // T-BUG2 (parity-audit bug #2): the Linux equivalent of the macOS suite
  // above — same shape/coverage, but asserting Linux's real Ctrl-based
  // chords and confirming the nonexistent-on-Linux hints (save/new-snippet/
  // replace-snippet/settings) never appear at all, on any tab or capability
  // state (unlike macOS's `⌘S save`, which is only CONDITIONALLY shown —
  // Linux never shows it, full stop, since there is no bound chord for it).
  @Suite("ShortcutHints.text matrix (Linux)")
  struct LinuxShortcutHintsMatrixTests {

    private static let capabilityCases:
      [(name: String, capabilities: HighlightedItemCapabilities)] =
        [
          ("text/link", HighlightedItemCapabilities(item: makeClipItem(kind: .text))),
          (
            "richText (Alt+Enter plain)",
            HighlightedItemCapabilities(item: makeClipItem(kind: .richText))
          ),
          (
            "image w/o OCR",
            HighlightedItemCapabilities(item: makeClipItem(kind: .image, ocrText: nil))
          ),
          (
            "image w/ OCR (Alt+Enter OCR text)",
            HighlightedItemCapabilities(item: makeClipItem(kind: .image, ocrText: "text"))
          ),
          (
            "file",
            HighlightedItemCapabilities(
              item: makeClipItem(kind: .file, fileReference: "file:///tmp/x"))
          ),
          ("nil / nothing highlighted", HighlightedItemCapabilities(item: nil)),
        ]

    @Test(
      "Every tab × capability-state combination: Alt+Enter wording matches the capability; save/new/replace/settings never appear",
      arguments: PickerTab.allCases, Self.capabilityCases)
    func matchesCapability(
      tab: PickerTab, testCase: (name: String, capabilities: HighlightedItemCapabilities)
    ) {
      let hints = ShortcutHints.text(for: tab, capabilities: testCase.capabilities)

      switch testCase.capabilities.altEnterHint {
      case .plain:
        #expect(hints.contains("Alt+Enter plain"))
        #expect(!hints.contains("OCR text"))
      case .ocrText:
        #expect(hints.contains("Alt+Enter OCR text"))
        #expect(!hints.contains("Alt+Enter plain"))
      case nil:
        #expect(!hints.contains("Alt+Enter"))
      }

      // T-BUG2's core assertion: none of these ever appear, on ANY tab or
      // capability state — `KeyEventMapping.swift` binds none of them.
      #expect(!hints.contains("save"))
      #expect(!hints.contains("new"))
      #expect(!hints.contains("replace"))
      #expect(!hints.contains("settings"))
      #expect(!hints.contains("⌘"))
      #expect(!hints.contains("⌥"))
    }

    @Test("Every combination uses real Ctrl-based chords for search/move/tabs")
    func everyCombinationUsesRealChords() {
      for tab in PickerTab.allCases {
        for testCase in Self.capabilityCases {
          let hints = ShortcutHints.text(for: tab, capabilities: testCase.capabilities)
          #expect(hints.contains("↑/↓ move"))
          #expect(hints.contains("Enter paste"))
          #expect(hints.contains("Ctrl+F search"))
          #expect(hints.hasSuffix("Ctrl+1/2/3 tabs"))
        }
      }
    }

    @Test("History tab, exact hint string for text/link (no Alt+Enter, real Ctrl chords, no save)")
    func historyTextExact() {
      #expect(
        ShortcutHints.text(
          for: .history,
          capabilities: HighlightedItemCapabilities(item: makeClipItem(kind: .text)))
          == "↑/↓ move · Enter paste · Ctrl+F search · Ctrl+P pin · Delete delete · Ctrl+1/2/3 tabs"
      )
    }

    @Test("History tab, exact hint string for .richText (Alt+Enter plain)")
    func historyRichTextExact() {
      #expect(
        ShortcutHints.text(
          for: .history,
          capabilities: HighlightedItemCapabilities(item: makeClipItem(kind: .richText)))
          == "↑/↓ move · Enter paste · Alt+Enter plain · Ctrl+F search · Ctrl+P pin · Delete delete · Ctrl+1/2/3 tabs"
      )
    }

    @Test("History tab, exact hint string for OCR-bearing .image (Alt+Enter OCR text)")
    func historyImageOCRExact() {
      #expect(
        ShortcutHints.text(
          for: .history,
          capabilities: HighlightedItemCapabilities(
            item: makeClipItem(kind: .image, ocrText: "text")))
          == "↑/↓ move · Enter paste · Alt+Enter OCR text · Ctrl+F search · Ctrl+P pin · Delete delete · Ctrl+1/2/3 tabs"
      )
    }

    @Test("Pinned tab mirrors History for every capability state")
    func pinnedMirrorsHistory() {
      for testCase in Self.capabilityCases {
        #expect(
          ShortcutHints.text(for: .pinned, capabilities: testCase.capabilities)
            == ShortcutHints.text(for: .history, capabilities: testCase.capabilities))
      }
    }

    @Test("Snippets tab, exact hint string — no new/replace group, since neither is bound on Linux")
    func snippetsExact() {
      #expect(
        ShortcutHints.text(for: .snippets, capabilities: HighlightedItemCapabilities(item: nil))
          == "↑/↓ move · Enter paste · Ctrl+F search · Delete delete · Ctrl+1/2/3 tabs"
      )
    }
  }
#endif
