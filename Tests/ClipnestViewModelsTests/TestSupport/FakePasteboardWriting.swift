// FakePasteboardWriting.swift
//
// A `PasteboardWriting` fake that records writes in memory instead of
// touching the real system pasteboard — per coding-standards.md ("NO real
// `NSPasteboard`... from a test"). Mirrors
// `Tests/ClipnestCoreTests/PasterTests.swift`'s private
// `FakePasteboardWriting` (that one is file-private to its own test file, so
// this is a separate, `ClipnestViewModelsTests`-only copy rather than a
// shared import).
//
// P5 (Phase 3, Linux port): `NSPasteboard.PasteboardType` (AppKit-only)
// replaced with `ClipMediaType` — `PasteboardWriting.writeString(_:forType:)`/
// `writeData(_:forType:)` already take `ClipMediaType`, a portable
// typealias for `NSPasteboard.PasteboardType` on macOS and a plain struct on
// Linux (see `ClipnestCore/Clipboard/ClipMediaType.swift`) — this fake was
// simply spelling macOS's alias out instead of using the portable name it
// aliases; identical type, identical behavior on macOS, now compiles on
// Linux too. `import AppKit` dropped — nothing else in this file uses it.

import ClipnestCore
import Foundation

final class FakePasteboardWriting: PasteboardWriting, @unchecked Sendable {
  private(set) var writtenString: String?
  private(set) var writtenType: ClipMediaType?
  private(set) var writtenData: Data?
  private(set) var writtenDataType: ClipMediaType?
  private(set) var writtenRTF: Data?
  private(set) var writtenPlain: String?
  private(set) var writtenFileURL: URL?
  private(set) var writeCount = 0
  /// Mirrors real `NSPasteboard.changeCount` semantics closely enough for
  /// tests: increments on every write, starting from an arbitrary non-zero
  /// value so `0` never accidentally looks like a legitimate change count.
  private(set) var changeCount = 7

  func writeString(_ string: String, forType type: ClipMediaType) {
    writtenString = string
    writtenType = type
    writeCount += 1
    changeCount += 1
  }

  func writeData(_ data: Data, forType type: ClipMediaType) {
    writtenData = data
    writtenDataType = type
    writeCount += 1
    changeCount += 1
  }

  func writeRichText(rtf: Data, plain: String) {
    writtenRTF = rtf
    writtenPlain = plain
    writeCount += 1
    changeCount += 1
  }

  func writeFileURL(_ url: URL) {
    writtenFileURL = url
    writeCount += 1
    changeCount += 1
  }
}
