import ClipnestPlatformLinux
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("ShellHelperRequests / ShellHelperResponses")
struct AppShellHelperProtocolTests {
  @Test("getCapabilities() calls Properties.Get(app.clipnest.ShellHelper1, Capabilities)")
  func getCapabilitiesMessageShape() {
    let message = ShellHelperRequests.getCapabilities(serial: 1)
    #expect(message.destination == "app.clipnest.ShellHelper")
    #expect(message.path == "/app/clipnest/ShellHelper")
    #expect(message.interface == "org.freedesktop.DBus.Properties")
    #expect(message.body == [.string("app.clipnest.ShellHelper1"), .string("Capabilities")])
  }

  @Test("sendKeyChord() carries keyval and modifiers verbatim")
  func sendKeyChordMessageShape() {
    let message = ShellHelperRequests.sendKeyChord(keyval: 118, modifiers: 4, serial: 1)
    #expect(message.member == "SendKeyChord")
    #expect(message.body == [.uint32(118), .uint32(4)])
  }

  @Test("placeWindow() carries the window token and geometry")
  func placeWindowMessageShape() {
    let message = ShellHelperRequests.placeWindow(
      windowToken: "abc-123", x: 10, y: 20, flags: 5, serial: 1)
    #expect(message.member == "PlaceWindow")
    #expect(message.body == [.string("abc-123"), .int32(10), .int32(20), .uint32(5)])
  }

  @Test("parseCapabilities unwraps the variant<array<string>> shape")
  func parseCapabilitiesUnwrapsVariant() {
    let reply = fakeMethodReturn(body: [.variant(.array([.string("clipboard"), .string("paste")]))])
    #expect(ShellHelperResponses.parseCapabilities(reply) == ["clipboard", "paste"])
  }

  @Test("parseGetPointer extracts x/y/monitor")
  func parseGetPointerExtractsFields() {
    let reply = fakeMethodReturn(body: [.int32(5), .int32(6), .int32(0)])
    let parsed = ShellHelperResponses.parseGetPointer(reply)
    #expect(parsed?.x == 5)
    #expect(parsed?.y == 6)
    #expect(parsed?.monitor == 0)
  }

  @Test("parseGetMonitorWorkArea extracts the (x,y,width,height) structure")
  func parseGetMonitorWorkAreaExtractsStructure() {
    let reply = fakeMethodReturn(body: [
      .structure([.int32(0), .int32(0), .int32(1920), .int32(1080)])
    ])
    let parsed = ShellHelperResponses.parseGetMonitorWorkArea(reply)
    #expect(parsed?.width == 1920)
    #expect(parsed?.height == 1080)
  }

  @Test("parseShortcutActivated extracts action/timestamp/pointer/monitor")
  func parseShortcutActivatedExtractsFields() {
    let signal = DBusMessage(
      type: .signal, serial: 1, member: "ShortcutActivated",
      body: [
        .string("toggle-picker"), .uint32(1000), .int32(10), .int32(20), .int32(0),
        .array([]),
      ])
    let parsed = ShellHelperResponses.parseShortcutActivated(signal)
    #expect(parsed?.action == "toggle-picker")
    #expect(parsed?.pointerX == 10)
    #expect(parsed?.pointerY == 20)
  }

  @Test("showPickerOptions(forAction:) maps pointer/monitor straight through")
  func showPickerOptionsMapsFieldsThrough() {
    let action = (
      action: "toggle-picker", timestamp: UInt32(1), pointerX: Int32(3), pointerY: Int32(4),
      monitor: Int32(1)
    )
    let options = ShellHelperResponses.showPickerOptions(forAction: action)
    #expect(options.pointer?.x == 3)
    #expect(options.pointer?.y == 4)
    #expect(options.monitor == 1)
  }

  // MARK: - addSignalsMatch (T-P10J regression)

  @Test(
    "addSignalsMatch scopes the rule to the ShellHelper interface + object path, not a specific member — one rule must receive all three signals"
  )
  func addSignalsMatchScopesToInterfaceAndPath() {
    let message = ShellHelperRequests.addSignalsMatch(serial: 21)
    #expect(message.member == "AddMatch")
    #expect(message.destination == "org.freedesktop.DBus")
    guard case .string(let rule)? = message.body.first else {
      Issue.record("expected the match rule string")
      return
    }
    #expect(rule.contains("type='signal'"))
    #expect(rule.contains("interface='app.clipnest.ShellHelper1'"))
    #expect(rule.contains("path='/app/clipnest/ShellHelper'"))
    // Deliberately NOT scoped to a single `member=` — see this method's doc
    // comment: ShortcutActivated/ClipboardChanged/CapabilitiesChanged all
    // need to ride this one rule.
    #expect(!rule.contains("member="))
  }

  @Test("isCapabilitiesChanged recognizes the signal by type + member")
  func isCapabilitiesChangedRecognizesSignal() {
    let signal = DBusMessage(type: .signal, serial: 1, member: "CapabilitiesChanged", body: [])
    #expect(ShellHelperResponses.isCapabilitiesChanged(signal))
  }

  @Test("isCapabilitiesChanged rejects a method return or a differently-named signal")
  func isCapabilitiesChangedRejectsWrongShapes() {
    let wrongMember = DBusMessage(type: .signal, serial: 1, member: "ShortcutActivated", body: [])
    #expect(!ShellHelperResponses.isCapabilitiesChanged(wrongMember))

    let notASignal = fakeMethodReturn(body: [])
    #expect(!ShellHelperResponses.isCapabilitiesChanged(notASignal))
  }
}
