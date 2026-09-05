import ClipnestPlatformLinux
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("SingleInstanceDecision")
struct AppSingleInstanceDecisionTests {
  @Test("primaryOwner becomes primary")
  func primaryOwnerBecomesPrimary() {
    #expect(SingleInstanceDecision.decide(requestNameReply: .primaryOwner) == .becomePrimary)
  }

  @Test("alreadyOwner (re-requesting a name this exact connection already owns) becomes primary")
  func alreadyOwnerBecomesPrimary() {
    #expect(SingleInstanceDecision.decide(requestNameReply: .alreadyOwner) == .becomePrimary)
  }

  @Test("inQueue forwards to the running instance")
  func inQueueForwards() {
    #expect(
      SingleInstanceDecision.decide(requestNameReply: .inQueue) == .forwardToRunningInstance)
  }

  @Test("exists forwards to the running instance")
  func existsForwards() {
    #expect(SingleInstanceDecision.decide(requestNameReply: .exists) == .forwardToRunningInstance)
  }

  @Test("a nil reply (timeout/error) is treated as bus-unavailable, not a crash")
  func nilReplyIsBusUnavailable() {
    #expect(SingleInstanceDecision.decide(requestNameReply: nil) == .busUnavailable)
  }
}

@Suite("SingleInstance.acquire / forwardArguments")
struct AppSingleInstanceTests {
  @Test("acquire sends Hello then RequestName with DO_NOT_QUEUE, and decodes primaryOwner")
  func acquireSendsHelloThenRequestName() {
    let fake = FakeDBusCalling(scriptedReplies: [
      fakeMethodReturn(), fakeMethodReturn(body: [.uint32(1)]),
    ])
    let decision = SingleInstance.acquire(on: fake, timeout: .milliseconds(50))

    #expect(decision == .becomePrimary)
    #expect(fake.sentMessages.count == 2)
    #expect(fake.sentMessages[0].member == "Hello")
    #expect(fake.sentMessages[1].member == "RequestName")
    guard case .string(let name) = fake.sentMessages[1].body[0] else {
      Issue.record("expected the bus name as the first RequestName argument")
      return
    }
    #expect(name == "app.clipnest.Clipnest")
    guard case .uint32(let flags) = fake.sentMessages[1].body[1] else {
      Issue.record("expected flags as the second RequestName argument")
      return
    }
    #expect(flags == 0x4, "DO_NOT_QUEUE must always be set — see SingleInstance's doc comment")
  }

  @Test("acquire never sends RequestName if Hello itself fails")
  func acquireStopsAfterFailedHello() {
    let fake = FakeDBusCalling(scriptedReplies: [])
    let decision = SingleInstance.acquire(on: fake, timeout: .milliseconds(50))
    #expect(decision == .busUnavailable)
    #expect(fake.sentMessages.count == 1)
  }

  @Test("forwardArguments sends Open with the given argv when non-empty")
  func forwardArgumentsSendsOpen() {
    let fake = FakeDBusCalling(scriptedReplies: [fakeMethodReturn()])
    SingleInstance.forwardArguments(["--toggle-picker"], on: fake)

    #expect(fake.sentMessages.count == 1)
    #expect(fake.sentMessages[0].member == "Open")
    guard case .array(let uris) = fake.sentMessages[0].body[0] else {
      Issue.record("expected the argv array as Open's first argument")
      return
    }
    #expect(uris == [.string("--toggle-picker")])
  }

  @Test("forwardArguments sends bare Activate when there is no argv to forward")
  func forwardArgumentsSendsActivateWhenEmpty() {
    let fake = FakeDBusCalling(scriptedReplies: [fakeMethodReturn()])
    SingleInstance.forwardArguments([], on: fake)

    #expect(fake.sentMessages.count == 1)
    #expect(fake.sentMessages[0].member == "Activate")
  }
}
