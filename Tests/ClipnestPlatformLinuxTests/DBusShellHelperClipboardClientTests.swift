import ClipnestPlatformLinux
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

#if canImport(Glibc)
  import Glibc
#endif

/// A scripted `DBusCalling` fake that ALSO overrides the fd-carrying call
/// overload — `Tests/ClipnestPlatformLinuxTests/AppFakeDBusCalling.swift`'s
/// `FakeDBusCalling` deliberately doesn't (see `DBusCalling`'s doc comment:
/// the default extension implementation returns `nil`/"unsupported" for
/// every conformer that predates fd support), so `ShellHelperClient`'s five
/// clipboard-payload methods need a fake that actually answers it. Two
/// independent scripted-reply queues, matching `ShellHelperClient`'s own
/// two-call-shape design: `refreshCapabilities()` only ever uses the plain
/// overload, the clipboard methods only ever use the fd-carrying one.
private final class FakeShellHelperFileDescriptorCalling: DBusCalling, @unchecked Sendable {
  private(set) var sentMessages: [DBusMessage] = []
  private(set) var attachedFileDescriptorsPerCall: [[Int32]] = []
  private var scriptedPlainReplies: [DBusMessage?]
  private var scriptedFileDescriptorReplies: [(message: DBusMessage, fileDescriptors: [Int32])?]

  init(
    scriptedPlainReplies: [DBusMessage?] = [],
    scriptedFileDescriptorReplies: [(message: DBusMessage, fileDescriptors: [Int32])?] = []
  ) {
    self.scriptedPlainReplies = scriptedPlainReplies
    self.scriptedFileDescriptorReplies = scriptedFileDescriptorReplies
  }

  func call(_ message: DBusMessage, timeout: Duration) -> DBusMessage? {
    sentMessages.append(message)
    guard !scriptedPlainReplies.isEmpty else { return nil }
    return scriptedPlainReplies.removeFirst()
  }

  func call(
    _ message: DBusMessage, attachingFileDescriptors: [Int32], timeout: Duration
  ) -> (message: DBusMessage, fileDescriptors: [Int32])? {
    sentMessages.append(message)
    attachedFileDescriptorsPerCall.append(attachingFileDescriptors)
    guard !scriptedFileDescriptorReplies.isEmpty else { return nil }
    return scriptedFileDescriptorReplies.removeFirst()
  }
}

/// `ShellHelperClient`'s five clipboard-payload methods (task P8-C) — no
/// real socket, no real bus, matching every other `ShellHelperClient` test
/// in this target (`AppShellHelperClientTests.swift`). What's real here is
/// the fd OWNERSHIP contract: `readClipboard`'s failure paths are checked
/// against genuine pipe fds (via `fcntl(F_GETFD)`) so "closed, not leaked"
/// is actually verified, not just asserted.
@Suite("ShellHelperClient — clipboard payload methods, fake fd-aware connection")
struct DBusShellHelperClipboardClientTests {
  /// Negotiates `.clipboard` via the plain-call queue (consuming its first
  /// two scripted replies — `NameHasOwner` then `Capabilities.Get`,
  /// mirroring `AppShellHelperClientTests
  /// .ownerPresentQueriesAndParsesCapabilities`), then leaves the REST of
  /// `plainReplies` queued for whichever of `setClipboardWatch`/
  /// `getClipboardMimeTypes` the test calls next — those two members carry
  /// no `h` argument in either direction (only `ReadClipboard`/
  /// `SetClipboard` do), so `ShellHelperClient` correctly routes them
  /// through the ordinary `call(_:timeout:)`, not the fd-carrying overload.
  private func makeClientWithClipboardCapability(
    plainReplies: [DBusMessage?] = [],
    scriptedFileDescriptorReplies: [(message: DBusMessage, fileDescriptors: [Int32])?] = []
  ) -> (ShellHelperClient, FakeShellHelperFileDescriptorCalling) {
    let fake = FakeShellHelperFileDescriptorCalling(
      scriptedPlainReplies: [
        fakeMethodReturn(body: [.boolean(true)]),
        fakeMethodReturn(body: [.variant(.array([.string("clipboard")]))]),
      ] + plainReplies, scriptedFileDescriptorReplies: scriptedFileDescriptorReplies)
    let client = ShellHelperClient(callConnection: fake, signalConnection: nil)
    _ = client.refreshCapabilities()
    return (client, fake)
  }

  @Test("clipboard payload calls refuse without the negotiated .clipboard capability")
  func clipboardCallsRefuseWithoutCapability() {
    let fake = FakeShellHelperFileDescriptorCalling(
      scriptedPlainReplies: [fakeMethodReturn(body: [.boolean(false)])])
    let client = ShellHelperClient(callConnection: fake, signalConnection: nil)
    _ = client.refreshCapabilities()

    #expect(client.setClipboardWatch(enable: true, includePrimary: false) == false)
    #expect(client.getClipboardMimeTypes(selection: .clipboard) == nil)
    #expect(client.readClipboard(selection: .clipboard, mimetype: "text/plain") == nil)
    #expect(client.setClipboard(mimetype: "text/plain", fileDescriptor: 999) == nil)
    // Only the initial NameHasOwner call — none of the four above should
    // have sent anything once the capability check short-circuited.
    #expect(fake.sentMessages.count == 1)
  }

  @Test("setClipboardWatch sends both flags and succeeds on any methodReturn")
  func setClipboardWatchSendsBothFlags() {
    let (client, fake) = makeClientWithClipboardCapability(plainReplies: [fakeMethodReturn()])

    #expect(client.setClipboardWatch(enable: true, includePrimary: true))
    #expect(fake.sentMessages.last?.body == [.boolean(true), .boolean(true)])
  }

  @Test("getClipboardMimeTypes parses (mimeTypes, clipboardSerial) from a valid reply")
  func getClipboardMimeTypesParsesReply() {
    let (client, fake) = makeClientWithClipboardCapability(
      plainReplies: [
        fakeMethodReturn(
          body: [.array([.string("text/plain"), .string("image/png")]), .uint64(7)])
      ])

    let result = client.getClipboardMimeTypes(selection: .clipboard)

    #expect(result?.mimeTypes == ["text/plain", "image/png"])
    #expect(result?.clipboardSerial == 7)
    #expect(fake.sentMessages.last?.member == "GetClipboardMimeTypes")
  }

  #if canImport(Glibc)
    @Test("readClipboard returns the real fd from a valid reply")
    func readClipboardReturnsFileDescriptorOnValidReply() {
      var pipeFDs: [Int32] = [0, 0]
      let pipeResult = pipeFDs.withUnsafeMutableBufferPointer { buffer in
        pipe(buffer.baseAddress)
      }
      #expect(pipeResult == 0)
      let (readEnd, writeEnd) = (pipeFDs[0], pipeFDs[1])
      defer {
        close(readEnd)
        close(writeEnd)
      }
      let (client, fake) = makeClientWithClipboardCapability(
        scriptedFileDescriptorReplies: [
          (message: fakeMethodReturn(body: [.unixFD(0)]), fileDescriptors: [readEnd])
        ])

      let result = client.readClipboard(selection: .clipboard, mimetype: "text/plain")

      #expect(result == readEnd)
      #expect(fake.sentMessages.last?.member == "ReadClipboard")
    }

    @Test("readClipboard closes any fd from a shape-invalid reply rather than leak it")
    func readClipboardClosesFileDescriptorOnInvalidReplyShape() {
      var pipeFDs: [Int32] = [0, 0]
      let pipeResult = pipeFDs.withUnsafeMutableBufferPointer { buffer in
        pipe(buffer.baseAddress)
      }
      #expect(pipeResult == 0)
      let (readEnd, writeEnd) = (pipeFDs[0], pipeFDs[1])
      defer { close(writeEnd) }
      let (client, _) = makeClientWithClipboardCapability(
        scriptedFileDescriptorReplies: [
          (message: fakeMethodReturn(body: [.string("not-an-fd")]), fileDescriptors: [readEnd])
        ])

      let result = client.readClipboard(selection: .clipboard, mimetype: "text/plain")

      #expect(result == nil)
      // Deliberately NOT `fcntl(readEnd, F_GETFD) == -1` (T-FLAKE1): the
      // instant `readClipboard` really closes `readEnd`, that integer
      // re-enters the PROCESS-WIDE fd-allocation pool — swift-testing runs
      // suites concurrently within one process, so another suite's own
      // `open`/`pipe`/`socket` call can be handed that exact number before
      // this assertion runs, and `fcntl(F_GETFD)` has no way to know it's
      // now looking at a completely different, unrelated open file
      // description. That coincidental reuse is what made this test flake
      // (observed failing once, then passing 3 consecutive full runs plus
      // an isolated-suite run) — the assertion was correct in intent but
      // asked a process-global, shared-namespace question instead of a
      // question scoped to the one kernel object this test actually owns.
      //
      // Ask the PIPE instead of the fd table: `readEnd` and `writeEnd` are
      // the two ends of a pipe this test alone created, so once `readEnd`'s
      // open file description is truly gone (refcount to zero — nothing
      // else in this test process holds another reference to it), the
      // kernel reports that fact on `writeEnd`, which only this test holds
      // and only this test could ever close. `poll()` (not a `write()`) is
      // used so the check needs no `SIGPIPE` handling: POSIX guarantees a
      // pipe's write end reports `POLLERR` once it has no more readers,
      // and `revents` reports `POLLERR`/`POLLHUP` unconditionally — they
      // aren't valid members of the `events` request field (see `poll(2)`)
      // — so `events: 0` still surfaces it. Zero-timeout, non-blocking:
      // `readClipboard` above already returned, so the close (if it
      // happened) has already landed. Same `pollfd`/`POLLIN`-family Glibc
      // API `X11ClipboardConnection.runEventLoop` already uses in
      // production, just checking a different revent.
      var polledWriteEnd = pollfd(fd: writeEnd, events: 0, revents: 0)
      let pollResult = poll(&polledWriteEnd, 1, 0)
      #expect(pollResult >= 0)
      #expect(
        polledWriteEnd.revents & Int16(POLLERR) != 0,
        "the fd must have been closed, not leaked — its pipe's write end should observe POLLERR once its only reader is gone"
      )
    }

    @Test("setClipboard attaches the caller's fd at wire index 0 and parses the returned serial")
    func setClipboardAttachesFileDescriptorAndParsesSerial() {
      let (client, fake) = makeClientWithClipboardCapability(
        scriptedFileDescriptorReplies: [
          (message: fakeMethodReturn(body: [.uint64(3)]), fileDescriptors: [])
        ])

      let result = client.setClipboard(mimetype: "text/plain", fileDescriptor: 123)

      #expect(result == 3)
      #expect(fake.attachedFileDescriptorsPerCall.last == [123])
      #expect(fake.sentMessages.last?.body == [.string("text/plain"), .unixFD(0)])
    }
  #endif

  @Test("readClipboard/getClipboardMimeTypes/setClipboard degrade to nil on no reply, not a crash")
  func noReplyDegradesGracefully() {
    let (client, _) = makeClientWithClipboardCapability(scriptedFileDescriptorReplies: [])

    #expect(client.getClipboardMimeTypes(selection: .clipboard) == nil)
    #expect(client.readClipboard(selection: .clipboard, mimetype: "text/plain") == nil)
    #expect(client.setClipboard(mimetype: "text/plain", fileDescriptor: 7) == nil)
  }
}
