// StoreOpenFailureAlert.swift
//
// T-STOREALERT1: thin AppKit shell over `StoreOpenFailureRecovery` (all copy and
// file logic live there, unit-tested). Shown when `AppEnvironment()` throws at
// launch, instead of the old silent terminate.

import AppKit
import ClipnestCore
import ClipnestViewModels

@MainActor
enum StoreOpenFailureAlert {
  typealias Recovery = StoreOpenFailureRecovery

  /// Asks the user what to do about `error`. Returns the choice; for
  /// `.resetHistory` the second confirmation has already been accepted.
  static func ask(error: Error) -> Recovery.Choice {
    // Menu-bar (accessory) app: without activating, the alert opens behind
    // other windows.
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = Recovery.alertTitle
    alert.informativeText = Recovery.alertMessage(errorSummary: Recovery.summary(for: error))
    alert.addButton(withTitle: Recovery.resetButtonTitle)
    alert.addButton(withTitle: Recovery.showInFinderButtonTitle)
    alert.addButton(withTitle: Recovery.quitButtonTitle)
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      return confirmReset() ? .resetHistory : ask(error: error)
    case .alertSecondButtonReturn:
      return .showInFinder
    default:
      return .quit
    }
  }

  private static func confirmReset() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = Recovery.confirmTitle
    alert.informativeText = Recovery.confirmMessage()
    alert.addButton(withTitle: Recovery.confirmResetButtonTitle)
    alert.addButton(withTitle: Recovery.cancelButtonTitle)
    return alert.runModal() == .alertFirstButtonReturn
  }

  static func showFinalFailure(error: Error, backupFolder: URL?) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = Recovery.finalFailureTitle
    alert.informativeText = Recovery.finalFailureMessage(
      errorSummary: Recovery.summary(for: error),
      backupFolder: Recovery.backupFolder(from: error, known: backupFolder))
    alert.addButton(withTitle: Recovery.quitButtonTitle)
    alert.runModal()
  }

  static func revealDataFolder() {
    NSWorkspace.shared.activateFileViewerSelecting([BlobStore.defaultBaseDirectory()])
  }
}
