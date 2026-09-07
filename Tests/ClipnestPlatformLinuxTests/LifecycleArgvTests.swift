import ClipnestPlatformLinux
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

/// Covers the pure decision logic `LinuxAppLifecycle.run(arguments:)` is
/// built from: which CLI command a launch's argv maps to (used both for a
/// fresh primary launch and for a forwarded second-instance invocation —
/// see `ClipnestControlDispatcher`'s `.open` case, which parses the exact
/// same way), and the `GlobalShortcuts` portal's detection-only capability
/// check (see `HotkeyBackend.globalShortcutsPortal`'s doc comment for why
/// this tier is detection-only in this build).
@Suite("LinuxAppCLI.parse")
struct LifecycleArgvCLITests {
  @Test("recognizes --toggle-picker")
  func recognizesTogglePicker() {
    #expect(LinuxAppCLI.parse(["--toggle-picker"]) == .togglePicker)
  }

  @Test("recognizes --expand-snippet")
  func recognizesExpandSnippet() {
    #expect(LinuxAppCLI.parse(["--expand-snippet"]) == .expandSnippet)
  }

  @Test("an empty argv (a plain launch with no flags) is .none")
  func emptyArgvIsNone() {
    #expect(LinuxAppCLI.parse([]) == .none)
  }

  @Test("an unrecognized flag is .none, not a crash")
  func unrecognizedFlagIsNone() {
    #expect(LinuxAppCLI.parse(["--not-a-real-flag"]) == .none)
  }

  @Test("toggle-picker is recognized even alongside other unrelated arguments")
  func recognizesFlagAmongOtherArguments() {
    #expect(LinuxAppCLI.parse(["/usr/bin/clipnest", "--toggle-picker"]) == .togglePicker)
  }

  // T-BB2 regression: black-box testing on Ubuntu 22.04 found `--version`/
  // `--help` unrecognized by this parser entirely — both fell through to
  // `.none`, which `LinuxAppLifecycle.run(arguments:)` used to treat as a
  // plain launch (full resident GUI with no instance running, exit-124
  // hang for the tester; silent no-op forward with one running).
  @Test("recognizes --version")
  func recognizesVersion() {
    #expect(LinuxAppCLI.parse(["--version"]) == .version)
  }

  @Test("recognizes --help")
  func recognizesHelp() {
    #expect(LinuxAppCLI.parse(["--help"]) == .help)
  }
}

/// `LinuxAppCLI.usageText` — the exact stdout `--help` prints (T-BB2 fix).
/// Content assertions only (the actual print+exit(0)+no-window/no-forward
/// behavior is verified end-to-end in the real `.deb`, not here — `exit(0)`
/// cannot be safely called from inside this test binary).
@Suite("LinuxAppCLI.usageText")
struct LifecycleArgvUsageTextTests {
  @Test("mentions every flag parse(_:) actually recognizes")
  func mentionsEveryRecognizedFlag() {
    let text = LinuxAppCLI.usageText
    #expect(text.contains(LinuxAppCLIFlag.togglePicker))
    #expect(text.contains(LinuxAppCLIFlag.expandSnippet))
    #expect(text.contains(LinuxAppCLIFlag.version))
    #expect(text.contains(LinuxAppCLIFlag.help))
  }

  @Test("mentions clipnest-ctl for scripting a running instance")
  func mentionsClipnestCtl() {
    #expect(LinuxAppCLI.usageText.contains("clipnest-ctl"))
  }
}

@Suite("GlobalShortcutsPortalClient.isAvailable — fake connection, no real bus")
struct LifecycleGlobalShortcutsPortalTests {
  @Test("unavailable when the portal's bus name has no owner at all")
  func unavailableWhenNoOwner() {
    let fake = FakeDBusCalling(scriptedReplies: [fakeMethodReturn(body: [.boolean(false)])])
    #expect(!GlobalShortcutsPortalClient.isAvailable(on: fake, timeout: .milliseconds(50)))
    #expect(fake.sentMessages.count == 1, "must not probe the interface when there's no owner")
  }

  @Test("available when the bus name is owned AND the interface answers introspection")
  func availableWhenOwnedAndIntrospectable() {
    let fake = FakeDBusCalling(scriptedReplies: [
      fakeMethodReturn(body: [.boolean(true)]), fakeMethodReturn(body: [.array([])]),
    ])
    #expect(GlobalShortcutsPortalClient.isAvailable(on: fake, timeout: .milliseconds(50)))
  }

  @Test("unavailable when owned but the interface probe itself fails (no such interface)")
  func unavailableWhenProbeFails() {
    let fake = FakeDBusCalling(scriptedReplies: [fakeMethodReturn(body: [.boolean(true)])])
    #expect(!GlobalShortcutsPortalClient.isAvailable(on: fake, timeout: .milliseconds(50)))
  }
}
