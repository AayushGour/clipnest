import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("HotkeyBackendResolver priority chain")
struct AppHotkeyBackendTests {
  @Test("the Shell-extension keybinding wins when advertised AND a live probe confirms it")
  func shellExtensionWinsWhenAvailableAndConfirmed() {
    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: true, shellExtensionLiveDispatchConfirmed: true,
      xGrabKeyAvailable: true, globalShortcutsPortalAvailable: true)
    #expect(backend == .shellExtensionKeybinding)
  }

  @Test(
    "P10-C regression: an installed-but-broken extension (Capabilities says hotkeys, but no method actually dispatches) falls through instead of claiming and killing the hotkey"
  )
  func brokenExtensionFallsThroughDespiteAdvertisingHotkeys() {
    // This is exactly the audit's finding: `_tryEnable('hotkeys', ...)`
    // genuinely succeeds (grabbing the mutter keybinding is a real side
    // effect independent of whether the method table dispatches), so
    // `shellExtensionKeybindingAvailable` is true — but the live probe
    // (a real GetPointer call) never got a real reply because the service
    // exports no methods at all.
    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: true, shellExtensionLiveDispatchConfirmed: false,
      xGrabKeyAvailable: false, globalShortcutsPortalAvailable: false)
    #expect(
      backend == .gsettingsFloor,
      "must NOT select shellExtensionKeybinding — that tier would never fire")
  }

  @Test(
    "a live probe succeeding without the capability being advertised still does not select the tier"
  )
  func liveProbeAloneIsNotEnoughWithoutTheCapability() {
    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: false, shellExtensionLiveDispatchConfirmed: true,
      xGrabKeyAvailable: true, globalShortcutsPortalAvailable: true)
    #expect(backend == .xGrabKey)
  }

  @Test("XGrabKey is used when the extension is absent but XGrabKey is available")
  func xGrabKeyIsSecondPriority() {
    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: false, shellExtensionLiveDispatchConfirmed: false,
      xGrabKeyAvailable: true, globalShortcutsPortalAvailable: true)
    #expect(backend == .xGrabKey)
  }

  @Test("the GlobalShortcuts portal is used when neither the extension nor XGrabKey are available")
  func portalIsThirdPriority() {
    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: false, shellExtensionLiveDispatchConfirmed: false,
      xGrabKeyAvailable: false, globalShortcutsPortalAvailable: true)
    #expect(backend == .globalShortcutsPortal)
  }

  @Test("the GSettings floor is used when nothing else is available — the universal fallback")
  func gsettingsFloorIsLastResort() {
    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: false, shellExtensionLiveDispatchConfirmed: false,
      xGrabKeyAvailable: false, globalShortcutsPortalAvailable: false)
    #expect(backend == .gsettingsFloor)
  }
}
