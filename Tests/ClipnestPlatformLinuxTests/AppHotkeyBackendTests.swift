import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("HotkeyBackendResolver priority chain")
struct AppHotkeyBackendTests {
  @Test("the Shell-extension keybinding always wins when available")
  func shellExtensionWinsWhenAvailable() {
    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: true, xGrabKeyAvailable: true,
      globalShortcutsPortalAvailable: true)
    #expect(backend == .shellExtensionKeybinding)
  }

  @Test("XGrabKey is used when the extension is absent but XGrabKey is available")
  func xGrabKeyIsSecondPriority() {
    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: false, xGrabKeyAvailable: true,
      globalShortcutsPortalAvailable: true)
    #expect(backend == .xGrabKey)
  }

  @Test("the GlobalShortcuts portal is used when neither the extension nor XGrabKey are available")
  func portalIsThirdPriority() {
    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: false, xGrabKeyAvailable: false,
      globalShortcutsPortalAvailable: true)
    #expect(backend == .globalShortcutsPortal)
  }

  @Test("the GSettings floor is used when nothing else is available — the universal fallback")
  func gsettingsFloorIsLastResort() {
    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: false, xGrabKeyAvailable: false,
      globalShortcutsPortalAvailable: false)
    #expect(backend == .gsettingsFloor)
  }
}
