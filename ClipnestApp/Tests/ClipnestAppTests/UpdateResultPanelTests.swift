// UpdateResultPanelTests.swift
//
// T-UPDALERT2: the update-check result is a NON-modal panel. These cover the
// parts that don't need a window server: window configuration (the properties
// that make it appear on the current/full-screen Space and never block the
// app), button -> action mapping, default/cancel buttons, single instance.
// Never ordered on-screen from a test. Module name is `Clipnest`.

import AppKit
import ClipnestViewModels
import Testing

@testable import Clipnest

@MainActor
@Suite("UpdateResultPanel", .serialized)
struct UpdateResultPanelTests {
  private let available = UpdateCheckFeedback(outcome: .updateAvailable(latest: "9.9.9"))
  private let upToDate = UpdateCheckFeedback(outcome: .upToDate(installed: "1.0.0"))

  @Test func windowConfigJoinsCurrentSpaceAndDoesNotHideOnDeactivate() {
    let panel = UpdateResultPanel(feedback: available, onUpdate: {})
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(panel.level == UpdateResultPanel.windowLevel)
    #expect(!panel.hidesOnDeactivate)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.canBecomeKey)
  }

  @Test func buttonTitlesFollowFeedback() {
    #expect(UpdateResultPanel.buttonTitles(for: available) == ["Update", "Later"])
    #expect(UpdateResultPanel.buttonTitles(for: upToDate) == ["OK"])
  }

  @Test func onlyFirstButtonOfAvailableMapsToUpdate() {
    #expect(UpdateResultPanel.buttonActions(for: available) == [.update, .dismiss])
    #expect(UpdateResultPanel.buttonActions(for: upToDate) == [.dismiss])
  }

  private func key(_ code: UInt16) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
      keyCode: code)!
  }

  @Test func returnKeyRunsUpdateAndClears() {
    UpdateResultPanel.current?.close()
    var updates = 0
    let panel = UpdateResultPanel.present(feedback: available, onUpdate: { updates += 1 })
    panel.keyDown(with: key(36))
    #expect(updates == 1)
    #expect(UpdateResultPanel.current == nil)
  }

  @Test func escapeKeyDismissesAndClears() {
    UpdateResultPanel.current?.close()
    var updates = 0
    let panel = UpdateResultPanel.present(feedback: available, onUpdate: { updates += 1 })
    panel.keyDown(with: key(53))
    #expect(updates == 0)
    #expect(UpdateResultPanel.current == nil)
  }

  @Test func presentWithDifferentFeedbackReplacesStaleContent() {
    UpdateResultPanel.current?.close()
    var updates = 0
    let first = UpdateResultPanel.present(feedback: upToDate, onUpdate: {})
    let second = UpdateResultPanel.present(feedback: available, onUpdate: { updates += 1 })
    #expect(first !== second)
    #expect(UpdateResultPanel.current === second)
    second.defaultButton?.performClick(nil)
    #expect(updates == 1)
  }

  @Test func defaultButtonIsReturnKeyAndRunsUpdate() {
    var updates = 0
    let panel = UpdateResultPanel(feedback: available, onUpdate: { updates += 1 })
    #expect(panel.defaultButton?.title == "Update")
    #expect(panel.defaultButton?.keyEquivalent == "\r")
    panel.defaultButton?.performClick(nil)
    #expect(updates == 1)
  }

  @Test func escapeDismissesWithoutUpdating() {
    var updates = 0
    let panel = UpdateResultPanel(feedback: available, onUpdate: { updates += 1 })
    #expect(panel.cancelButton?.title == "Later")
    panel.cancelOperation(nil)
    #expect(updates == 0)
    #expect(UpdateResultPanel.current == nil || UpdateResultPanel.current !== panel)
  }

  @Test func laterButtonDoesNotUpdate() {
    var updates = 0
    let panel = UpdateResultPanel(feedback: available, onUpdate: { updates += 1 })
    panel.cancelButton?.performClick(nil)
    #expect(updates == 0)
    #expect(UpdateResultPanel.current !== panel)
  }

  @Test func upToDateHasSingleOKButtonThatIsBothDefaultAndCancel() {
    let panel = UpdateResultPanel(feedback: upToDate, onUpdate: {})
    #expect(panel.defaultButton?.title == "OK")
    #expect(panel.cancelButton === panel.defaultButton)
  }

  @Test func presentIsSingleInstanceAndClearsOnClose() {
    UpdateResultPanel.current?.close()
    let first = UpdateResultPanel.present(feedback: upToDate, onUpdate: {})
    let second = UpdateResultPanel.present(feedback: upToDate, onUpdate: {})
    #expect(first === second)
    #expect(UpdateResultPanel.current === first)
    first.close()
    #expect(UpdateResultPanel.current == nil)
  }
}
