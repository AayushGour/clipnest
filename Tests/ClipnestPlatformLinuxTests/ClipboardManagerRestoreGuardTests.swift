import Foundation
import Testing

@testable import ClipnestPlatformLinux

/// The exact targets measured on GNOME 46 for each owner in the leak this
/// guard closes (see `ClipboardManagerRestoreGuard`'s doc comment).
private enum MeasuredTargets {
  static let hintedCopy = ["x-kde-passwordManagerHint", "text/plain;charset=utf-8", "UTF8_STRING"]
  static let mutterRestore = ["text/plain;charset=utf-8", "UTF8_STRING"]
  static let gtkTextCopy = [
    "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT", "COMPOUND_TEXT",
  ]
}

@Suite("ClipboardManagerRestoreGuard")
struct ClipboardManagerRestoreGuardTests {
  @Test("A hinted copy is concealed")
  func hintedCopyIsConcealed() {
    var guardState = ClipboardManagerRestoreGuard()
    let concealed = guardState.isConcealed(mimeTypes: MeasuredTargets.hintedCopy, serial: 1)
    #expect(concealed)
  }

  @Test("mutter's restore of a hinted copy is concealed too")
  func restoreAfterHintedCopyIsConcealed() {
    var guardState = ClipboardManagerRestoreGuard()
    _ = guardState.isConcealed(mimeTypes: MeasuredTargets.hintedCopy, serial: 1)
    let concealed = guardState.isConcealed(mimeTypes: MeasuredTargets.mutterRestore, serial: 2)
    #expect(concealed)
  }

  @Test("The same restore shape after an ordinary copy is captured")
  func restoreAfterOrdinaryCopyIsNotConcealed() {
    var guardState = ClipboardManagerRestoreGuard()
    _ = guardState.isConcealed(mimeTypes: MeasuredTargets.gtkTextCopy, serial: 1)
    let concealed = guardState.isConcealed(mimeTypes: MeasuredTargets.mutterRestore, serial: 2)
    #expect(!concealed)
  }

  @Test("A real app's copy after a hinted copy disarms the guard")
  func realCopyDisarms() {
    var guardState = ClipboardManagerRestoreGuard()
    _ = guardState.isConcealed(mimeTypes: MeasuredTargets.hintedCopy, serial: 1)
    let realCopyConcealed = guardState.isConcealed(
      mimeTypes: MeasuredTargets.gtkTextCopy, serial: 2)
    #expect(!realCopyConcealed)
    let laterRestoreConcealed = guardState.isConcealed(
      mimeTypes: MeasuredTargets.mutterRestore, serial: 3)
    #expect(!laterRestoreConcealed)
  }

  @Test("The empty moment between release and restore doesn't disarm the guard")
  func emptyTargetsAreNeutral() {
    var guardState = ClipboardManagerRestoreGuard()
    _ = guardState.isConcealed(mimeTypes: MeasuredTargets.hintedCopy, serial: 1)
    let emptyConcealed = guardState.isConcealed(mimeTypes: [], serial: 2)
    #expect(!emptyConcealed)
    let restoreConcealed = guardState.isConcealed(
      mimeTypes: MeasuredTargets.mutterRestore, serial: 3)
    #expect(restoreConcealed)
  }

  @Test("Asking again about the same serial returns the same verdict")
  func verdictIsStablePerSerial() {
    var guardState = ClipboardManagerRestoreGuard()
    _ = guardState.isConcealed(mimeTypes: MeasuredTargets.hintedCopy, serial: 1)
    for _ in 0..<3 {
      let concealed = guardState.isConcealed(mimeTypes: MeasuredTargets.mutterRestore, serial: 2)
      #expect(concealed)
    }
  }

  @Test("Only one real MIME type besides X11 text aliases has the restore shape")
  func restoreShape() {
    let hasRestoreShape = ClipboardManagerRestoreGuard.hasClipboardManagerRestoreShape
    #expect(hasRestoreShape(MeasuredTargets.mutterRestore))
    #expect(hasRestoreShape(["image/png"]))
    #expect(!hasRestoreShape(MeasuredTargets.gtkTextCopy))
    #expect(!hasRestoreShape(["UTF8_STRING", "STRING"]))
  }
}
