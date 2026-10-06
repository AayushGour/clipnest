import ClipnestPlatformLinux
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("ShellHelperClient.refreshCapabilities — fake connection, no real bus")
struct AppShellHelperClientTests {
  @Test(
    "when NameHasOwner is false, capabilities are .unavailable and Capabilities is never queried")
  func noOwnerNeverQueriesCapabilities() {
    let fake = FakeDBusCalling(scriptedReplies: [fakeMethodReturn(body: [.boolean(false)])])
    let client = ShellHelperClient(callConnection: fake, signalConnection: nil)

    let result = client.refreshCapabilities()

    #expect(result == .unavailable)
    #expect(fake.sentMessages.count == 1, "Capabilities.Get must not be sent when there's no owner")
  }

  @Test("when NameHasOwner is true, Capabilities is queried and parsed into the negotiated set")
  func ownerPresentQueriesAndParsesCapabilities() {
    let fake = FakeDBusCalling(scriptedReplies: [
      fakeMethodReturn(body: [.boolean(true)]),
      fakeMethodReturn(body: [.variant(.array([.string("clipboard"), .string("paste")]))]),
    ])
    let client = ShellHelperClient(callConnection: fake, signalConnection: nil)

    let result = client.refreshCapabilities()

    #expect(result.isPresent)
    #expect(result.capabilities == [.clipboard, .paste])
    #expect(fake.sentMessages.count == 2)
    #expect(fake.sentMessages[0].member == "NameHasOwner")
    #expect(fake.sentMessages[1].interface == "org.freedesktop.DBus.Properties")
  }

  @Test("onCapabilitiesChanged fires only when the negotiated result actually changes")
  func onCapabilitiesChangedFiresOnlyOnRealChange() {
    let fake = FakeDBusCalling(scriptedReplies: [
      fakeMethodReturn(body: [.boolean(false)]),
      fakeMethodReturn(body: [.boolean(false)]),
    ])
    let client = ShellHelperClient(callConnection: fake, signalConnection: nil)
    var changeCount = 0
    client.onCapabilitiesChanged = { _ in changeCount += 1 }

    _ = client.refreshCapabilities()
    _ = client.refreshCapabilities()

    #expect(changeCount == 0, "both refreshes agree on .unavailable — nothing changed")
  }

  @Test("a call that never replies degrades to .unavailable rather than crashing")
  func noReplyDegradesGracefully() {
    let fake = FakeDBusCalling(scriptedReplies: [])
    let client = ShellHelperClient(callConnection: fake, signalConnection: nil)
    #expect(client.refreshCapabilities() == .unavailable)
  }

  @Test("sendKeyChord/getPointer/placeWindow refuse to call when the capability isn't negotiated")
  func callsRefuseWithoutNegotiatedCapability() {
    let fake = FakeDBusCalling(scriptedReplies: [fakeMethodReturn(body: [.boolean(false)])])
    let client = ShellHelperClient(callConnection: fake, signalConnection: nil)
    _ = client.refreshCapabilities()

    #expect(client.sendKeyChord(keyval: 1, modifiers: 0) == false)
    #expect(client.getPointer() == nil)
    #expect(client.placeWindow(windowToken: "x", x: 0, y: 0, flags: 0) == false)
    // Only the initial NameHasOwner call — none of the three above should
    // have sent anything, since the capability check short-circuits first.
    #expect(fake.sentMessages.count == 1)
  }

  // MARK: - probeLiveDispatch (P10-C: closes the hotkey capability trap)

  @Test("probeLiveDispatch returns true only on a real, correctly-shaped GetPointer reply")
  func probeLiveDispatchTrueOnValidReply() {
    let fake = FakeDBusCalling(scriptedReplies: [
      fakeMethodReturn(body: [.boolean(true)]),
      fakeMethodReturn(body: [.variant(.array([.string("hotkeys")]))]),
      fakeMethodReturn(body: [.int32(1), .int32(2), .int32(0)]),
    ])
    let client = ShellHelperClient(callConnection: fake, signalConnection: nil)
    _ = client.refreshCapabilities()

    #expect(client.probeLiveDispatch())
    #expect(fake.sentMessages.last?.member == "GetPointer")
  }

  @Test(
    "probeLiveDispatch returns false when the extension advertises hotkeys but dispatches nothing (the P10-C stub-service bug)"
  )
  func probeLiveDispatchFalseWhenExtensionAdvertisesButDoesNotDispatch() {
    // NameHasOwner true, Capabilities claims "hotkeys" — but the scripted
    // GetPointer reply is absent, mirroring a service that exports no
    // methods at all (a real call to it would time out / UnknownMethod;
    // `DBusCalling.call` returning nil is `ShellHelperClient`'s own
    // documented no-reply contract, matching a real timeout here).
    let fake = FakeDBusCalling(scriptedReplies: [
      fakeMethodReturn(body: [.boolean(true)]),
      fakeMethodReturn(body: [.variant(.array([.string("hotkeys")]))]),
    ])
    let client = ShellHelperClient(callConnection: fake, signalConnection: nil)
    _ = client.refreshCapabilities()

    #expect(!client.probeLiveDispatch())
  }

  @Test(
    "probeLiveDispatch short-circuits to false without sending anything when no extension is present"
  )
  func probeLiveDispatchShortCircuitsWithoutOwner() {
    let fake = FakeDBusCalling(scriptedReplies: [fakeMethodReturn(body: [.boolean(false)])])
    let client = ShellHelperClient(callConnection: fake, signalConnection: nil)
    _ = client.refreshCapabilities()

    #expect(!client.probeLiveDispatch())
    // Only the initial NameHasOwner call — the `isPresent` guard must skip
    // the GetPointer round trip entirely.
    #expect(fake.sentMessages.count == 1)
  }

  @Test(
    "probeLiveDispatch ignores currentCapabilities.supports(.pointer) — it calls GetPointer directly"
  )
  func probeLiveDispatchBypassesThePointerCapabilityGate() {
    // Deliberately advertises "hotkeys" WITHOUT "pointer" — the public
    // `getPointer()` method would refuse to call at all here (it gates on
    // `.supports(.pointer)`), but `probeLiveDispatch()` must not: trusting
    // any self-reported capability string is exactly the bug being fixed.
    let fake = FakeDBusCalling(scriptedReplies: [
      fakeMethodReturn(body: [.boolean(true)]),
      fakeMethodReturn(body: [.variant(.array([.string("hotkeys")]))]),
      fakeMethodReturn(body: [.int32(5), .int32(6), .int32(1)]),
    ])
    let client = ShellHelperClient(callConnection: fake, signalConnection: nil)
    _ = client.refreshCapabilities()

    #expect(client.getPointer() == nil, "getPointer() itself still gates on .pointer")
    #expect(client.probeLiveDispatch(), "but probeLiveDispatch() bypasses that gate on purpose")
  }
}
