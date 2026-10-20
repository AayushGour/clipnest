// RowAccessibilityTests.swift
//
// T-AUD-VO: spoken labels for picker rows, tab/filter names, relative time.

import ClipnestCore
import Foundation
import Testing

@testable import ClipnestViewModels

@Suite("RowAccessibility labels (T-AUD-VO)")
struct RowAccessibilityTests {
  @Test("plain text row: kind, time, excerpt")
  func textRow() {
    let item = makeClipItem(kind: .text, previewText: "hello world")
    #expect(
      RowAccessibility.itemLabel(for: item, relativeTime: "2 minutes ago")
        == "Text, 2 minutes ago: hello world")
  }

  @Test("pinned rows say so, between kind and time")
  func pinnedRow() {
    let item = makeClipItem(kind: .link, previewText: "https://a.b", pinned: true)
    #expect(
      RowAccessibility.itemLabel(for: item, relativeTime: "just now")
        == "Link, pinned, just now: https://a.b")
  }

  @Test("image row speaks dimensions as 'W by H' and has no excerpt")
  func imageRow() {
    let item = makeClipItem(kind: .image, previewText: "Image, 1200\u{00D7}800")
    #expect(
      RowAccessibility.itemLabel(for: item, relativeTime: "5 minutes ago")
        == "Image, 1200 by 800, 5 minutes ago")
  }

  @Test("image with recognized text mentions it")
  func imageWithOCR() {
    let item = makeClipItem(kind: .image, previewText: "Image, 10\u{00D7}20", ocrText: "abc")
    #expect(
      RowAccessibility.itemLabel(for: item, relativeTime: "just now")
        == "Image, 10 by 20, has recognized text, just now")
  }

  @Test("long and multi-line previews are collapsed and cut at 80 characters with an ellipsis")
  func excerptIsBounded() {
    let long = String(repeating: "abcdefghij\n", count: 20)
    let label = RowAccessibility.itemLabel(
      for: makeClipItem(previewText: long), relativeTime: "just now")
    let excerpt = String(label.dropFirst("Text, just now: ".count))
    #expect(excerpt.count == RowAccessibility.previewCharacterLimit + 1)
    #expect(excerpt.hasSuffix("\u{2026}"))
    #expect(!excerpt.contains("\n"))
  }

  @Test("a 2 MB preview is bounded: <= 81 characters with an ellipsis, and fast")
  func hugePreviewIsBoundedAndFast() {
    let huge = String(repeating: "word ", count: 400_000)
    let clock = ContinuousClock()
    var excerpt = ""
    let elapsed = clock.measure { excerpt = RowAccessibility.excerpt(of: huge) }
    #expect(excerpt.count <= RowAccessibility.previewCharacterLimit + 1)
    #expect(excerpt.hasSuffix("\u{2026}"))
    #expect(elapsed < .milliseconds(50))
  }

  @Test("heavy leading whitespace still yields the correct excerpt")
  func heavyWhitespacePrefix() {
    let leading = String(repeating: " \n", count: 100)
    let text = leading + "hello" + String(repeating: " ", count: 1_000_000)
    #expect(RowAccessibility.excerpt(of: text) == "hello\u{2026}")
    #expect(RowAccessibility.excerpt(of: "  a   b ") == "a b")
  }

  @Test("empty preview omits the colon")
  func emptyPreview() {
    #expect(
      RowAccessibility.itemLabel(for: makeClipItem(previewText: "  \n "), relativeTime: "just now")
        == "Text, just now")
  }

  @Test("snippet label: title, optional keyword, body excerpt")
  func snippetLabels() {
    #expect(
      RowAccessibility.snippetLabel(
        for: Snippet(title: "Greeting", body: "Hello there", keyword: "hi"))
        == "Snippet Greeting, keyword hi: Hello there")
    #expect(
      RowAccessibility.snippetLabel(for: Snippet(title: "Sig", body: "Best,\nMe"))
        == "Snippet Sig: Best, Me")
    #expect(
      RowAccessibility.snippetLabel(for: Snippet(title: "Empty", body: "", keyword: ""))
        == "Snippet Empty")
  }

  @Test("plain-text paste is offered only where it differs from the default paste")
  func plainTextSupport() {
    #expect(RowAccessibility.supportsPlainTextPaste(makeClipItem(kind: .richText)))
    #expect(RowAccessibility.supportsPlainTextPaste(makeClipItem(kind: .image, ocrText: "x")))
    #expect(!RowAccessibility.supportsPlainTextPaste(makeClipItem(kind: .image)))
    #expect(!RowAccessibility.supportsPlainTextPaste(makeClipItem(kind: .text)))
    #expect(!RowAccessibility.supportsPlainTextPaste(makeClipItem(kind: .file)))
  }

  @Test("tab labels are full names")
  func tabLabels() {
    let labels = PickerTab.allCases.map(\.accessibilityLabel)
    #expect(labels == ["History tab", "Pinned tab", "Snippets tab"])
  }
}

@Suite("RelativeTimeText (T-AUD-VO)")
struct RelativeTimeTextTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  @Test(
    "buckets and pluralisation",
    arguments: [
      (0, "just now"), (59, "just now"), (60, "1 minute ago"), (125, "2 minutes ago"),
      (3_599, "59 minutes ago"), (3_600, "1 hour ago"), (7_300, "2 hours ago"),
      (86_400, "1 day ago"), (3 * 86_400, "3 days ago"),
    ])
  func buckets(seconds: Int, expected: String) {
    #expect(
      RelativeTimeText.string(from: now.addingTimeInterval(-Double(seconds)), now: now)
        == expected)
  }

  @Test("a future date reads as just now")
  func future() {
    #expect(RelativeTimeText.string(from: now.addingTimeInterval(500), now: now) == "just now")
  }
}

@Suite("KindFilterOptions (T-AUD-KBD / T-AUD-VO)")
struct KindFilterOptionsTests {
  private let mac = KindFilterOptions.macOptions

  @Test("forward cycling visits every chip in order and wraps")
  func forwardWraps() {
    var current: ItemKind? = nil
    var seen: [ItemKind?] = []
    for _ in mac {
      current = KindFilterOptions.cycled(from: current, in: mac, step: 1)
      seen.append(current)
    }
    #expect(seen == [.text, .image, .file, .link, nil])
  }

  @Test("backward cycling from All wraps to the last chip")
  func backwardWraps() {
    #expect(KindFilterOptions.cycled(from: nil, in: mac, step: -1) == .link)
    #expect(KindFilterOptions.cycled(from: .link, in: mac, step: -1) == .file)
  }

  @Test("a filter outside the option set restarts from All")
  func unknownRestarts() {
    #expect(KindFilterOptions.cycled(from: .richText, in: mac, step: 1) == nil)
  }

  @Test("empty option set is a no-op")
  func emptyOptions() {
    #expect(KindFilterOptions.cycled(from: .text, in: [], step: 1) == .text)
  }

  @Test("linux options add Rich Text after Text's slot per ItemKind order and start at All")
  func linuxOptions() {
    #expect(KindFilterOptions.linuxOptions.first! == nil)
    #expect(KindFilterOptions.linuxOptions.count == ItemKind.allCases.count + 1)
  }

  @Test("every chip has a distinct full spoken name ending in 'filter'")
  func accessibilityLabels() {
    let labels = KindFilterOptions.linuxOptions.map(KindFilterOptions.accessibilityLabel(for:))
    #expect(Set(labels).count == labels.count)
    #expect(labels.allSatisfy { $0.hasSuffix(" filter") })
    #expect(KindFilterOptions.accessibilityLabel(for: .image) == "Images filter")
    #expect(KindFilterOptions.accessibilityLabel(for: nil) == "All items filter")
  }

  @Test("titles")
  func titles() {
    #expect(mac.map(KindFilterOptions.title(for:)) == ["All", "Text", "Image", "File", "Link"])
    #expect(KindFilterOptions.title(for: .richText) == "Rich Text")
  }
}

@Suite("PickerCommandShortcut (T-AUD-KBD)")
struct PickerCommandShortcutTests {
  private func command(
    _ character: Character, option: Bool = false, control: Bool = false,
    shift: Bool = false, command: Bool = true
  ) -> PickerCommandShortcut? {
    PickerCommandShortcut.command(
      character: character, command: command, option: option, control: control, shift: shift)
  }

  @Test("the four chords")
  func chords() {
    #expect(command("]") == .nextFilter)
    #expect(command("[") == .previousFilter)
    #expect(command("e") == .editSnippet)
    #expect(command("y") == .togglePreview)
  }

  @Test("⌥⌘E (the global snippet-expansion hotkey) and other extra modifiers never match")
  func extraModifiersRejected() {
    #expect(command("e", option: true) == nil)
    #expect(command("]", control: true) == nil)
    #expect(command("y", shift: true) == nil)
  }

  @Test("without ⌘ nothing matches, so typing e/y/[/] in the search field is untouched")
  func commandRequired() {
    for character in "[]eyEY" { #expect(command(character, command: false) == nil) }
  }

  @Test("existing chords are not claimed")
  func noCollisions() {
    for character in "fpsn123," { #expect(command(character) == nil) }
  }
}
