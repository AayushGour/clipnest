// FakePasteboard.swift
//
// A single fake that implements BOTH `MonitoredPasteboard` (the read side
// `ClipboardMonitor` polls) and `PasteboardWriting` (the write side `Paster`
// writes through) — deliberately one shared instance, mirroring production
// exactly (both `ClipboardMonitor` and `Paster` point at the same
// `NSPasteboard.general` singleton there). This is what makes the
// self-paste-suppression race scenario meaningful: a `Paster.paste(...)`
// write here is visible to a subsequent `ClipboardMonitor.checkNow()` poll
// against the very same fake, exactly like the real pasteboard.
//
// Never touches the real system pasteboard — per coding-standards.md's
// testing rule ("never touch real NSPasteboard from a test"), extended here
// to this standalone harness even though it isn't `ClipnestCoreTests`,
// because posting to the REAL pasteboard from an unattended stress run could
// clobber whatever the user's own clipboard held during the session.
import AppKit
import ClipnestCore
import Foundation

final class FakePasteboard: MonitoredPasteboard, PasteboardWriting, @unchecked Sendable {
  private let lock = NSLock()
  private var _availableTypes: [NSPasteboard.PasteboardType] = []
  private var _strings: [NSPasteboard.PasteboardType: String] = [:]
  private var _datas: [NSPasteboard.PasteboardType: Data] = [:]
  private var _changeCount = 0

  var availableTypes: [NSPasteboard.PasteboardType] {
    lock.lock()
    defer { lock.unlock() }
    return _availableTypes
  }

  var changeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _changeCount
  }

  func string(forType type: NSPasteboard.PasteboardType) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return _strings[type]
  }

  func data(forType type: NSPasteboard.PasteboardType) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return _datas[type]
  }

  private func replace(
    strings: [NSPasteboard.PasteboardType: String] = [:],
    datas: [NSPasteboard.PasteboardType: Data] = [:],
    types: [NSPasteboard.PasteboardType]
  ) {
    lock.lock()
    _strings = strings
    _datas = datas
    _availableTypes = types
    _changeCount += 1
    lock.unlock()
  }

  // MARK: - PasteboardWriting (what `Paster` calls)

  func writeString(_ string: String, forType type: NSPasteboard.PasteboardType) {
    replace(strings: [type: string], types: [type])
  }

  func writeData(_ data: Data, forType type: NSPasteboard.PasteboardType) {
    replace(datas: [type: data], types: [type])
  }

  func writeRichText(rtf: Data, plain: String) {
    replace(strings: [.string: plain], datas: [.rtf: rtf], types: [.rtf, .string])
  }

  func writeFileURL(_ url: URL) {
    replace(strings: [.fileURL: url.absoluteString], types: [.fileURL])
  }

  // MARK: - Simulated external copies (what a real user action produces)

  func simulateTextCopy(_ text: String) {
    replace(strings: [.string: text], types: [.string])
  }

  func simulateLinkCopy(_ url: String) {
    replace(strings: [.string: url], types: [.string])
  }

  func simulateImageCopy(_ data: Data, type: NSPasteboard.PasteboardType = .tiff) {
    replace(datas: [type: data], types: [type])
  }

  func simulateRichTextCopy(rtf: Data, fallbackPlainText: String?) {
    var strings: [NSPasteboard.PasteboardType: String] = [:]
    var types: [NSPasteboard.PasteboardType] = [.rtf]
    if let fallbackPlainText {
      strings[.string] = fallbackPlainText
      types.append(.string)
    }
    replace(strings: strings, datas: [.rtf: rtf], types: types)
  }

  func simulateFileCopy(_ urlString: String) {
    replace(strings: [.fileURL: urlString], types: [.fileURL])
  }

  func simulateConcealedCopy(_ text: String) {
    replace(
      strings: [.string: text],
      types: [.string, PrivacyFilter.concealedPasteboardType]
    )
  }

  /// Bumps `changeCount` with no content change — models a spurious
  /// pasteboard-owner churn some apps produce with no real new content.
  func bumpChangeCountOnly() {
    lock.lock()
    _changeCount += 1
    lock.unlock()
  }
}
