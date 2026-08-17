// FakePasteboardWriting.swift
//
// A `PasteboardWriting` fake that records writes in memory instead of
// touching the real system pasteboard — per coding-standards.md ("NO real
// `NSPasteboard`... from a test"). Mirrors
// `Tests/ClipnestCoreTests/PasterTests.swift`'s private
// `FakePasteboardWriting` (that one is file-private to its own test file, so
// this is a separate, App-test-target copy rather than a shared import).

import AppKit
import ClipnestCore
import Foundation

final class FakePasteboardWriting: PasteboardWriting, @unchecked Sendable {
  private(set) var writtenString: String?
  private(set) var writtenType: NSPasteboard.PasteboardType?
  private(set) var writtenData: Data?
  private(set) var writtenDataType: NSPasteboard.PasteboardType?
  private(set) var writtenRTF: Data?
  private(set) var writtenPlain: String?
  private(set) var writtenFileURL: URL?
  private(set) var writeCount = 0
  /// Mirrors real `NSPasteboard.changeCount` semantics closely enough for
  /// tests: increments on every write, starting from an arbitrary non-zero
  /// value so `0` never accidentally looks like a legitimate change count.
  private(set) var changeCount = 7

  func writeString(_ string: String, forType type: NSPasteboard.PasteboardType) {
    writtenString = string
    writtenType = type
    writeCount += 1
    changeCount += 1
  }

  func writeData(_ data: Data, forType type: NSPasteboard.PasteboardType) {
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
