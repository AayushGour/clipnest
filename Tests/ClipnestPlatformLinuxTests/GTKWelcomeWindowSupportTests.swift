import ClipnestViewModels
import Testing

@testable import ClipnestGTK

@Suite("WelcomeWindowSupport (T-WELCOME1-LX)")
struct GTKWelcomeWindowSupportTests {
  private let ctrl: UInt32 = 1 << 2
  private let shift: UInt32 = 1 << 0
  private let lock: UInt32 = 1 << 1

  @Test("Esc closes; Ctrl+W closes (either case); Caps Lock is ignored")
  func closeKeys() {
    #expect(WelcomeKeyAction.action(keyval: 0xff1b, state: 0) == .close)
    #expect(WelcomeKeyAction.action(keyval: 0x77, state: ctrl) == .close)
    #expect(WelcomeKeyAction.action(keyval: 0x57, state: ctrl | lock) == .close)
  }

  @Test("Bare W, Ctrl+Shift+W and Return are not handled by the window")
  func nonCloseKeys() {
    #expect(WelcomeKeyAction.action(keyval: 0x77, state: 0) == nil)
    #expect(WelcomeKeyAction.action(keyval: 0x77, state: ctrl | shift) == nil)
    #expect(WelcomeKeyAction.action(keyval: 0xff0d, state: 0) == nil)
    #expect(WelcomeKeyAction.action(keyval: 0xff1b, state: ctrl) == nil)
  }

  @Test("Badges use shape + text, with spoken names for check/dash")
  func badges() {
    #expect(WelcomeStepBadge.text(for: .done, number: 2) == "✓")
    #expect(WelcomeStepBadge.text(for: .skipped, number: 2) == "–")
    #expect(WelcomeStepBadge.text(for: .current, number: 2) == "2")
    #expect(WelcomeStepBadge.accessibleLabel(for: .done) == "Done")
    #expect(WelcomeStepBadge.accessibleLabel(for: .skipped) == "Skipped")
    #expect(WelcomeStepBadge.accessibleLabel(for: .current) == nil)
  }

  @Test("Collapsed rows: current/upcoming show nothing; done/skipped show a status")
  func summaries() {
    func text(_ step: WelcomeStep, _ state: WelcomeStepState) -> String? {
      WelcomeRowSummary.text(
        step: step, state: state, hotkeyText: "Alt + Super + V", permissionSummary: "P",
        tryItStatus: "It works.")
    }
    #expect(text(.tryIt, .current) == nil)
    #expect(text(.permission, .upcoming) == nil)
    #expect(text(.tryIt, .upcoming) == "Alt + Super + V")
    #expect(text(.permission, .done) == "P")
    #expect(text(.permission, .skipped) == "P")
    #expect(text(.tryIt, .done) == "It works.")
    #expect(text(.tryIt, .skipped) == "Alt + Super + V")
    let unbound = WelcomeRowSummary.text(
      step: .tryIt, state: .skipped, hotkeyText: nil, permissionSummary: "P", tryItStatus: "")
    #expect(unbound == "No hotkey set")
  }
}
