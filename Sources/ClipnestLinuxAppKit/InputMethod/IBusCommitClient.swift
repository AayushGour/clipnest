import ClipnestCore
import ClipnestPlatformLinux
import ClipnestViewModels
import Foundation
import Synchronization

/// The stateful client that owns a live connection to IBus's private bus
/// and performs ONE snippet-expansion commit: **switch global engine ->
/// wait for a receptive widget to answer `SetSurroundingText` -> recover
/// the selection -> delete it + commit the replacement -> switch back.**
/// Tier 2 of D-IBUS-1's three-tier design (AT-SPI 1, IBus 2, clipboard 3) —
/// `LinuxIBusSelectionReplacer` (T-IBUS-REPLACER) is the one caller, via
/// the `IBusReplacing` seam, that maps `IBusCommitOutcome` onto
/// `ClipnestCore.SelectionReplaceResult`.
///
/// **Manual-verify only** — same convention as `ShellHelperClient`/
/// `ClipnestControlService`: no D-Bus daemon (let alone a real IBus
/// private bus) is reachable in the CI container this ships to, so
/// nothing in THIS file is exercised by `swift test`. Every collaborator
/// it's built from that IS pure (`IBusCrashSafetyStateMachine`,
/// `IBusCommitTransaction`, `IBusAddressResolution`, `IBusRequests`/
/// `IBusResponses`/`IBusEngineDispatcher`) is unit-tested directly
/// instead. The two design questions this file's architecture answers
/// (does the two-connection split avoid the switch/FocusIn deadlock; does
/// `FocusIn` arrive reliably and fast) were verified live against a real
/// `ibus-daemon` (1.5.29-rc2) on the project's test VM with a raw,
/// non-libibus two-connection probe mirroring this exact shape — see
/// `.claude/logs/senior-dev.md` for the measured numbers (this file's own
/// doc comments below cite the specific figures each design choice rests
/// on).
///
/// ## Architecture — two connections, not one (D-IBUS-4)
/// `registrationConnection` registers our component/engine and is the ONE
/// connection whose reader thread (`readLoop()`) ever calls
/// `receiveOneMessage` on it — every inbound `Factory.CreateEngine`/
/// `Engine.*` call the daemon makes arrives here and is replied to here,
/// and every OUTBOUND engine SIGNAL this app emits as the engine
/// (`DeleteSurroundingText`/`CommitText`) is also sent on THIS connection,
/// never `callConnection` — real ibus-daemon internally proxies an
/// engine's signals through whichever connection registered that engine
/// (`RegisterComponent`), so emitting them from a DIFFERENT connection
/// would not reach the daemon's own routing for this engine at all.
/// Concurrent `send()` calls on one connection (the reader thread's reply
/// sends + the commit-caller thread's signal sends) are safe — a single
/// `write`/`sendmsg` to a connected `AF_UNIX SOCK_STREAM` socket is
/// atomic with respect to other writers on Linux; it is concurrent READS
/// that are unsafe (`DBusConnection`'s own top doc comment), which is
/// exactly why this connection has exactly ONE reader (`readLoop()`) for
/// its whole life.
///
/// `callConnection` only ever does blocking send-then-wait-for-reply calls
/// (`SetGlobalEngine`/`GetGlobalEngine`) — mirrors `ShellHelperClient
/// .callConnection`'s identical role.
///
/// **Why two connections, verified, not just theorized:** the architect's
/// brief carried an unverified theory that this avoids a real deadlock in
/// libibus's own GI sync-call wrapper. This codebase does not use that
/// wrapper (raw hand-rolled D-Bus throughout), so that specific theory
/// doesn't directly transfer — but the STRUCTURAL case for two connections
/// holds independently: `DBusConnection.call(_:timeout:)`'s own reader
/// loop DISCARDS any message that isn't the reply it's waiting for (see
/// that method's doc comment: "there should be none on a connection
/// dedicated to calls"), so a single connection driving both an inbound
/// dispatch loop AND a blocking outbound `call` would either (a) have the
/// blocking call silently discard-and-never-reply-to an inbound
/// `CreateEngine`/`FocusIn` the daemon is waiting on before it can answer
/// OUR call — a real, deterministic deadlock, not a maybe — or (b) require
/// two threads racing to read the SAME connection, which
/// `DBusConnection`'s own doc comment already establishes as unsafe. Two
/// physical connections avoid both failure modes by construction: this was
/// confirmed live against the real daemon (RegisterComponent, then
/// SetGlobalEngine on the separate outbound connection, both completing
/// successfully in low single-digit milliseconds while CreateEngine/Enable/
/// FocusIn were served concurrently on the registration connection's own
/// independent reader thread — 3/3 clean runs, zero deadlocks, zero
/// timeouts).
///
/// ## Crash safety (D-IBUS-3)
/// See `IBusCrashSafetyStateMachine`'s own doc comment for the full
/// persist-before-switch/clear-after-confirmed-restore/reconcile-at-startup
/// state machine this class drives via `IBusCommitTransaction`.
/// `reconcileAtStartup()` runs as the very first thing `start()` does, on
/// `callConnection`, before this app's own component/engine is ever
/// registered.
///
/// ## The gate is `SetSurroundingText`, not `FocusIn` (correction, T-IBUS-REPLACER)
/// `CommitText`/`DeleteSurroundingText` are fire-and-forget signals with no
/// ack, so this protocol needs its OWN positive signal that a receptive
/// recipient exists before committing anything. An earlier version of this
/// class gated on `FocusIn` alone — but the very measurement that was
/// meant to support that gate disproves it on closer reading: `FocusIn`
/// arrived ~1ms after `SetGlobalEngine` **even with no GUI text field
/// focused at all** (a bare SSH session against an idle desktop), meaning
/// the daemon always has SOME "current" input context bound, not only when
/// a text-editable widget is actively focused. Gating on `FocusIn` would
/// make the clipboard-tier fall-through essentially never trigger while
/// reporting the terminal, no-retry `.committedUnconfirmed` outcome — worse
/// than the status quo bug this feature exists to fix.
///
/// The real gate (D-IBUS-5): once `FocusIn` confirms our engine is bound to
/// SOME context, `emitRequireSurroundingText()` sends
/// `RequireSurroundingText`. A REAL text-editable widget answers with a
/// genuine, synchronous `SetSurroundingText(text, cursor_pos, anchor_pos)`
/// round trip (GTK's `ibusimcontext.c` sets `IBUS_CAP_SURROUNDING_TEXT`
/// optimistically and only discovers a widget can't answer on the first
/// `retrieve-surrounding` failure, revoking the bit from then on — a
/// non-answering widget is expected, not an error). Its arrival is
/// strictly stronger proof than `FocusIn` alone, AND its `cursor_pos`/
/// `anchor_pos` recover the selected keyword with no synthesized
/// keystroke — see `IBusCommitOutcome`'s own doc comment for the full
/// writeup and `selectedText(in:cursorPos:anchorPos:)`/
/// `deleteOffsetAndCount(cursorPos:anchorPos:)` below for the arithmetic.
/// `waitForSurroundingText()` returning `nil` within
/// `surroundingTextTimeout` is what actually produces
/// `.noLiveRecipient` now; `.committedUnconfirmed` is reached only past
/// that gate, on a real, non-empty, matched selection.
public final class IBusCommitClient: @unchecked Sendable {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "IBusCommitClient")

  // MARK: - Identity constants (coding-standards.md: no magic strings —
  // every one of these is used at exactly one call site below, so it lives
  // here rather than in a shared constants module, matching
  // `ShellHelperClient.defaultTimeout`'s own single-owner precedent).

  /// Our `RegisterComponent` component name — `app.clipnest.*` matches
  /// every other well-known identity this app registers on a D-Bus-shaped
  /// bus (`app.clipnest.Clipnest`, `app.clipnest.ShellHelper`).
  private static let componentName = "app.clipnest.snippetengine"
  /// The one engine our component declares — never user-selectable (no
  /// icon/setup a real IBus UI would surface it through in a useful way);
  /// switched to only for the duration of one commit transaction.
  private static let engineName = "clipnest-snippet"
  private static let componentVersion = "1.0"

  /// Used to restore the global engine when `GetGlobalEngine`'s reply
  /// parses to "no engine currently set" (a real, valid state — e.g. a
  /// fresh session before any engine has ever been chosen; the VM's own
  /// baseline read `No engine is set` before this task's own verification
  /// work set one) — matches the architect's own POC framing ("the real
  /// build must force-reassert and verify `xkb:us::eng`").
  static let fallbackEngineName = "xkb:us::eng"

  /// Measured live against the real daemon (VM, `ibus` 1.5.29-rc2):
  /// `RegisterComponent`/`SetGlobalEngine`/`GetGlobalEngine` all round-trip
  /// in 1-5ms, 3/3 clean runs. Matches `ShellHelperClient.defaultTimeout`'s
  /// own reasoning (its OTHER synchronous-reply D-Bus members measured
  /// single-digit ms; 250ms is already roughly an order of magnitude of
  /// headroom) — reusing that exact value rather than inventing a second,
  /// unrelated number for the same class of call.
  public static let defaultCallTimeout: Duration = ShellHelperClient.defaultTimeout

  /// `FocusIn` measured arriving ~1ms after `SetGlobalEngine` was issued,
  /// 3/3 clean runs against the real daemon (a raw two-connection probe
  /// mirroring this class's own architecture — see this type's own top
  /// doc comment). 200ms leaves two full orders of magnitude of headroom
  /// for a slower physical machine and for Swift's own syscall path
  /// (unmeasured directly — the VM probe used dbus-python, not this
  /// Swift binary, see the caveat in this class's own top doc comment)
  /// while staying well short of being a noticeable UI stall on the
  /// `.noLiveRecipient` fall-through path.
  public static let defaultFocusInTimeout: Duration = .milliseconds(200)

  /// **Not independently measured on the VM (inference, named as such —
  /// T-IBUS-REPLACER)**: no live probe of the corrected `SetSurroundingText`
  /// gate exists yet, unlike `defaultFocusInTimeout` above. Chosen as the
  /// SAME order of magnitude as `defaultFocusInTimeout` because
  /// `SetSurroundingText` is one more synchronous round trip layered on
  /// top of the same daemon<->client D-Bus path `FocusIn` already
  /// measured at ~1ms — headroom, not a measurement. This only affects the
  /// fall-through-to-clipboard path's latency (the happy path, per the
  /// architect's own POC, is ~16-18ms total, well under either timeout);
  /// still worth live-verifying before shipping, per this task's own
  /// return-message caveat.
  public static let defaultSurroundingTextTimeout: Duration = .milliseconds(200)

  /// Matches `LinuxAppLifecycle.sessionBusConnectTimeout`'s existing
  /// precedent for `DBusConnection.connect(address:timeout:)`.
  public static let defaultConnectTimeout: Duration = .seconds(2)

  private let registrationConnection: DBusConnection
  private let callConnection: any DBusCalling
  private let crashSafety: IBusCrashSafetyStateMachine
  private let focusInTimeout: Duration
  private let surroundingTextTimeout: Duration
  private let callTimeout: Duration
  private var readerThread: Thread?

  private struct EngineState {
    var currentObjectPath: String?
    var nextEngineId = 1
    var didStart = false
  }
  private let engineState = Mutex<EngineState>(EngineState())

  /// Guards `focusInReceived` — armed (reset to `false`) immediately
  /// before `SetGlobalEngine` is issued (see `switchToOurEngine()`) so
  /// there is no missed-wakeup window between arming and a `FocusIn` that
  /// arrives before `waitForFocusIn()` starts waiting.
  private let focusInCondition = NSCondition()
  private var focusInReceived = false

  /// Guards `surroundingTextSnapshot` — same missed-wakeup-window
  /// discipline as `focusInCondition` above: armed (reset to `nil`)
  /// immediately before `SetGlobalEngine` is issued (see
  /// `switchToOurEngine()`), well before `RequireSurroundingText` is even
  /// sent, so a `SetSurroundingText` that arrives before
  /// `waitForSurroundingText()` starts waiting can never be missed.
  private let surroundingTextCondition = NSCondition()
  private var surroundingTextSnapshot: (text: String, cursorPos: UInt32, anchorPos: UInt32)?

  /// Built lazily so its closures can capture `self` weakly without the
  /// "used before all stored properties are initialized" restriction a
  /// direct `init`-body assignment would hit — evaluated once, on first
  /// access (`start()`'s `registerComponent()`/`readLoop()`), well after
  /// `init` has returned and every other stored property already has a
  /// value.
  private lazy var dispatcher: IBusEngineDispatcher = {
    IBusEngineDispatcher(
      onFocusIn: { [weak self] in self?.signalFocusIn() },
      onFocusOut: {},
      onEnable: {},
      onDisable: {},
      onReset: {},
      onSetCapabilities: { _ in },
      onProcessKeyEvent: { _, _, _ in },
      onSetSurroundingText: { [weak self] text, cursorPos, anchorPos in
        self?.signalSurroundingText(text: text.text, cursorPos: cursorPos, anchorPos: anchorPos)
      },
      onPropertyActivate: { _, _ in },
      onCreateEngine: { [weak self] engineName in
        self?.allocateEngineObjectPath(engineName: engineName) ?? IBusPath.engine(id: 0)
      })
  }()

  public init(
    registrationConnection: DBusConnection, callConnection: any DBusCalling,
    store: any KeyValueStore, focusInTimeout: Duration = IBusCommitClient.defaultFocusInTimeout,
    surroundingTextTimeout: Duration = IBusCommitClient.defaultSurroundingTextTimeout,
    callTimeout: Duration = IBusCommitClient.defaultCallTimeout
  ) {
    self.registrationConnection = registrationConnection
    self.callConnection = callConnection
    self.crashSafety = IBusCrashSafetyStateMachine(store: store)
    self.focusInTimeout = focusInTimeout
    self.surroundingTextTimeout = surroundingTextTimeout
    self.callTimeout = callTimeout
  }

  // MARK: - Resolve + connect (T-IBUS-PIDLIVE folded in here — the
  // connection layer, per that task's own note that the live-process
  // liveness syscall belongs where a syscall is already in scope)

  /// Resolves the IBus private-bus address (`IBusAddressResolution`),
  /// gates it on the daemon PID actually being alive (T-IBUS-PIDLIVE —
  /// `IBusAddressResolution` deliberately omits this live-process check;
  /// see that type's own doc comment), opens BOTH connections to it, and
  /// runs `start()`. Returns `nil` on any failure along that chain — no
  /// address, a stale/dead daemon PID, a failed socket connect, or a
  /// failed `start()` (registration refused) — matching
  /// `LinuxAppLifecycle.makeShellHelperClient`'s own "degrade to nil,
  /// caller treats IBus as simply absent this session" convention.
  public static func resolveAndConnect(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    store: any KeyValueStore,
    connectTimeout: Duration = IBusCommitClient.defaultConnectTimeout,
    callTimeout: Duration = IBusCommitClient.defaultCallTimeout,
    focusInTimeout: Duration = IBusCommitClient.defaultFocusInTimeout,
    surroundingTextTimeout: Duration = IBusCommitClient.defaultSurroundingTextTimeout
  ) -> IBusCommitClient? {
    let readFile: (String) -> String? = { path in try? String(contentsOfFile: path, encoding: .utf8)
    }
    guard
      let resolved = IBusAddressResolution.resolveWithDaemonPID(
        environment: environment, readFile: readFile)
    else { return nil }
    if let daemonPID = resolved.daemonPID, !IBusDaemonLiveness.isDaemonProcessAlive(pid: daemonPID)
    {
      logger.notice("resolveAndConnect: stale socket-address file, daemon pid \(daemonPID) is dead")
      return nil
    }
    guard
      let registrationConnection = DBusConnection.connect(
        address: resolved.address, timeout: connectTimeout),
      let outboundConnection = DBusConnection.connect(
        address: resolved.address, timeout: connectTimeout)
    else { return nil }
    let client = IBusCommitClient(
      registrationConnection: registrationConnection, callConnection: outboundConnection,
      store: store, focusInTimeout: focusInTimeout, surroundingTextTimeout: surroundingTextTimeout,
      callTimeout: callTimeout)
    guard client.start() else { return nil }
    return client
  }

  // MARK: - Startup

  /// Reconciles any crash-safety marker left by a previous run, registers
  /// our component, and starts `registrationConnection`'s reader thread.
  /// Returns `false` (never crashes/throws) if registration itself fails
  /// — the caller degrades to treating IBus as unavailable this session,
  /// same as a failed connect.
  @discardableResult
  public func start() -> Bool {
    reconcileAtStartup()
    guard registerComponent() else { return false }
    engineState.withLock { $0.didStart = true }

    let thread = Thread { [weak self] in self?.readLoop() }
    thread.name = "IBusCommitClient"
    readerThread = thread
    thread.start()
    return true
  }

  /// D-IBUS-3: **must run before anything else** — see
  /// `IBusCrashSafetyStateMachine.reconcileAtStartup`'s own doc comment.
  /// Runs entirely on `callConnection`, before `registrationConnection`
  /// is ever registered as an engine — no reader thread exists yet at
  /// this point, so this is a plain blocking call, not a race.
  private func reconcileAtStartup() {
    crashSafety.reconcileAtStartup { [callConnection, callTimeout] name in
      guard
        let reply = callConnection.call(
          IBusRequests.setGlobalEngine(name: name, serial: 1), timeout: callTimeout)
      else { return false }
      return IBusResponses.isSuccessReply(reply)
    }
  }

  /// Sends `RegisterComponent` directly on `registrationConnection`
  /// (its own blocking `call`, not `callConnection`) — safe because
  /// `readLoop()` hasn't started yet, so nothing else is reading this
  /// connection concurrently.
  private func registerComponent() -> Bool {
    let component = IBusComponentDescriptor(
      name: Self.componentName,
      description: "Clipnest snippet-expansion IBus commit engine",
      version: Self.componentVersion, license: "MIT", author: "Clipnest", homepage: "", exec: "",
      textDomain: "",
      engines: [
        IBusEngineDescriptor(
          name: Self.engineName, longName: "Clipnest",
          description:
            "Never user-selectable; switched to only for the duration of one snippet expansion.",
          language: "en")
      ])
    guard
      let reply = registrationConnection.call(
        IBusRequests.registerComponent(component, serial: 2), timeout: callTimeout)
    else { return false }
    return IBusResponses.isSuccessReply(reply)
  }

  /// The ONE reader of `registrationConnection` for its whole life — see
  /// this class's own top doc comment for why that invariant matters.
  /// Mirrors `ClipnestControlService.receiveLoop()`'s shape.
  private func readLoop() {
    Self.logger.info("IBus commit-engine registration connection read loop started")
    while true {
      guard let message = registrationConnection.receiveOneMessage(timeout: .seconds(1)) else {
        continue
      }
      guard let request = IBusInboundRequest.decode(message) else { continue }
      guard let reply = dispatcher.handle(request, message: message) else { continue }
      var outgoing = reply
      outgoing.serial = registrationConnection.allocateSerial()
      registrationConnection.send(outgoing)
    }
  }

  /// `IBusEngineDispatcher.onCreateEngine` — allocates a fresh engine
  /// object path and records it as the CURRENT one `performDeleteAndCommit`
  /// targets. `engineName` (the daemon's own echo of the name we
  /// registered) is unused — this app only ever registers one engine, so
  /// there is nothing to disambiguate by name.
  private func allocateEngineObjectPath(engineName: String) -> String {
    engineState.withLock { state in
      let path = IBusPath.engine(id: state.nextEngineId)
      state.nextEngineId += 1
      state.currentObjectPath = path
      return path
    }
  }

  private func signalFocusIn() {
    focusInCondition.lock()
    focusInReceived = true
    focusInCondition.signal()
    focusInCondition.unlock()
  }

  private func signalSurroundingText(text: String, cursorPos: UInt32, anchorPos: UInt32) {
    surroundingTextCondition.lock()
    surroundingTextSnapshot = (text, cursorPos, anchorPos)
    surroundingTextCondition.signal()
    surroundingTextCondition.unlock()
  }

  // MARK: - One commit transaction

  /// Performs ONE expansion: switch to our engine, wait (bounded) for
  /// `FocusIn`, ask for surrounding text and wait (bounded) for a
  /// receptive widget to answer, recover the selected keyword from that
  /// answer with no synthesized keystroke, ask `bodyForSelection` for a
  /// replacement, and on a match delete+commit — always attempting to
  /// restore the previous global engine afterward, regardless of outcome.
  /// See `IBusCommitOutcome`'s own doc comment for exactly what each
  /// result means and whether the caller may retry via another tier.
  ///
  /// Never logs the recovered selection or the replacement body
  /// themselves — only their Unicode-scalar lengths and the outcome,
  /// matching every other `ClipnestLogger` call site's privacy discipline
  /// (coding-standards.md).
  public func replaceSelection(bodyForSelection: sending @escaping (String) async -> String?) async
    -> IBusCommitOutcome
  {
    guard engineState.withLock({ $0.didStart }) else { return .unavailable }

    let transaction = IBusCommitTransaction(
      crashSafety: crashSafety,
      queryCurrentEngineName: { [weak self] in self?.queryGlobalEngineName() },
      switchToOurEngine: { [weak self] in self?.switchToOurEngine() },
      waitForFocusIn: { [weak self] in self?.waitForFocusIn() ?? false },
      requireSurroundingText: { [weak self] in self?.emitRequireSurroundingText() },
      waitForSurroundingText: { [weak self] in self?.waitForSurroundingText() },
      bodyForSelection: bodyForSelection,
      deleteAndCommit: { [weak self] offsetFromCursor, characterCount, text in
        self?.performDeleteAndCommit(
          offsetFromCursor: offsetFromCursor, characterCount: characterCount, text: text)
      },
      restoreEngine: { [weak self] name in self?.restoreGlobalEngine(to: name) ?? false })

    let outcome = await transaction.run()
    Self.logger.notice("replaceSelection transaction: outcome=\(outcome)")
    return outcome
  }

  /// `keyword`'s length in IBus's OWN accounting unit for
  /// `DeleteSurroundingText` — Unicode CHARACTERS (UCS-4 codepoints /
  /// Swift `unicodeScalars`), never Swift's default `String.count`
  /// (EXTENDED GRAPHEME CLUSTERS — e.g. `"e\u{301}"`, "e" + a combining
  /// acute accent, is ONE grapheme but TWO scalars) and never
  /// `.utf16.count` (surrogate-pair-sensitive — diverges from the scalar
  /// count for anything outside the Basic Multilingual Plane, which is
  /// most emoji). `IBusRequests.deleteSurroundingText`'s own doc comment
  /// traces this to the REAL deletion arithmetic in
  /// `ibus_engine_delete_surrounding_text` (`src/ibusengine.c`): it
  /// converts the cached surrounding text to UCS-4 (`g_utf8_to_ucs4_fast`)
  /// and indexes/`memmove`s over that `gunichar` array directly — one
  /// element per Unicode SCALAR, never a byte or a grapheme cluster.
  /// `.count`, `.utf16.count`, and `.unicodeScalars.count` all AGREE for
  /// plain ASCII — exactly the shape that already shipped an identical
  /// mistake once in this codebase (D95/T-ATSPI1: a wire-format
  /// assumption encoded the same way in production code AND its own unit
  /// test, CI green, 0% real-world success). `IBusCommitClientTests`
  /// exercises an emoji and a combining accent specifically because an
  /// ASCII-only test cannot distinguish these three counts and therefore
  /// proves nothing about which one is actually in use. Not used by
  /// `deleteOffsetAndCount(cursorPos:anchorPos:)` below (that arithmetic
  /// is already scalar-native, straight off the wire) — kept for any
  /// caller that logs a length (metadata only, never content).
  static func unicodeScalarCount(of text: String) -> UInt32 {
    UInt32(min(text.unicodeScalars.count, Int(UInt32.max)))
  }

  /// Recovers the selected-text substring from a `SetSurroundingText`
  /// snapshot, using `cursorPos`/`anchorPos` as Unicode-scalar (CHARACTER)
  /// offsets into `text` — never `String.Index`/grapheme clusters, never
  /// UTF-16 — matching `IBusInboundRequest.setSurroundingText`'s own
  /// upstream-cited unit. Returns `nil` (not the empty string) when
  /// `cursorPos == anchorPos` (nothing highlighted) or when either offset
  /// falls outside `text`'s own scalar range (a malformed/stale snapshot),
  /// so callers can tell "no selection" apart from "selection is the
  /// empty string" — which real IBus never actually sends but this
  /// function must not crash on either way (no force-unwraps,
  /// coding-standards.md).
  static func selectedText(in text: String, cursorPos: UInt32, anchorPos: UInt32) -> String? {
    guard cursorPos != anchorPos else { return nil }
    let scalars = text.unicodeScalars
    let lowerOffset = Int(min(cursorPos, anchorPos))
    let upperOffset = Int(max(cursorPos, anchorPos))
    guard upperOffset <= scalars.count else { return nil }
    let lower = scalars.index(scalars.startIndex, offsetBy: lowerOffset)
    let upper = scalars.index(scalars.startIndex, offsetBy: upperOffset)
    return String(String.UnicodeScalarView(scalars[lower..<upper]))
  }

  /// The `DeleteSurroundingText(offsetFromCursor:characterCount:)`
  /// arguments that delete exactly the `[min(cursorPos, anchorPos),
  /// max(cursorPos, anchorPos))` range a `SetSurroundingText` snapshot
  /// describes — covering BOTH selection directions (cursor at the
  /// selection's end, the common drag-then-release case, AND cursor at
  /// its start): `offsetFromCursor` is the signed distance from
  /// `cursorPos` to the LOWER bound (zero when the cursor already IS the
  /// lower bound; negative when the selection extends backward from it),
  /// `characterCount` is the selection's own length. Both arguments are
  /// already Unicode-scalar (CHARACTER) counts straight off the wire —
  /// see `IBusRequests.deleteSurroundingText`'s doc comment for the real
  /// upstream deletion arithmetic this mirrors. `Int32(clamping:)` guards
  /// the (practically unreachable) case of a document exceeding
  /// `Int32.max` characters, the same defensive-clamp precedent the old
  /// keyword-length arithmetic used.
  static func deleteOffsetAndCount(cursorPos: UInt32, anchorPos: UInt32) -> (
    offsetFromCursor: Int32, characterCount: UInt32
  ) {
    let lower = min(cursorPos, anchorPos)
    let characterCount = max(cursorPos, anchorPos) - lower
    let offsetFromCursor = Int32(clamping: Int64(lower) - Int64(cursorPos))
    return (offsetFromCursor, characterCount)
  }

  /// Arms the `FocusIn` gate (resets `focusInReceived`) AND the
  /// `SetSurroundingText` gate (resets `surroundingTextSnapshot`)
  /// IMMEDIATELY before issuing `SetGlobalEngine`, each under its own
  /// lock — so there is no window in which either signal arriving between
  /// arming and its own `waitFor...()` starting to wait could be silently
  /// missed.
  private func switchToOurEngine() {
    focusInCondition.lock()
    focusInReceived = false
    focusInCondition.unlock()

    surroundingTextCondition.lock()
    surroundingTextSnapshot = nil
    surroundingTextCondition.unlock()

    // Best-effort: this call's own success/failure is deliberately NOT
    // gating anything — see `IBusCommitTransaction.switchToOurEngine`'s
    // doc comment. The daemon may need to deliver `FocusIn` to us before
    // it can even reply to this call.
    _ = callConnection.call(
      IBusRequests.setGlobalEngine(name: Self.engineName, serial: 3), timeout: callTimeout)
  }

  private func waitForFocusIn() -> Bool {
    focusInCondition.lock()
    defer { focusInCondition.unlock() }
    let deadline = Date().addingTimeInterval(DurationConversion.timeInterval(for: focusInTimeout))
    while !focusInReceived {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      _ = focusInCondition.wait(until: Date().addingTimeInterval(remaining))
    }
    return focusInReceived
  }

  /// Emits `RequireSurroundingText` on our engine's current object path —
  /// only ever called after `waitForFocusIn()` returned `true` (asking
  /// before the engine is bound to a context has nothing to route to).
  /// A missing object path (cannot happen in practice — `FocusIn` only
  /// ever arrives on an engine object `CreateEngine` already allocated a
  /// path for) degrades to a logged no-op, never a force-unwrap/crash.
  private func emitRequireSurroundingText() {
    guard let objectPath = engineState.withLock({ $0.currentObjectPath }) else {
      Self.logger.error(
        "emitRequireSurroundingText: no engine object path recorded despite FocusIn")
      return
    }
    registrationConnection.send(
      IBusRequests.requireSurroundingText(
        objectPath: objectPath, serial: registrationConnection.allocateSerial()))
  }

  private func waitForSurroundingText() -> (text: String, cursorPos: UInt32, anchorPos: UInt32)? {
    surroundingTextCondition.lock()
    defer { surroundingTextCondition.unlock() }
    let deadline = Date().addingTimeInterval(
      DurationConversion.timeInterval(for: surroundingTextTimeout))
    while surroundingTextSnapshot == nil {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      _ = surroundingTextCondition.wait(until: Date().addingTimeInterval(remaining))
    }
    return surroundingTextSnapshot
  }

  /// `DeleteSurroundingText` + `CommitText`, in that order, on the SAME
  /// synchronous call — no `await`/`Task` hop between them (hard
  /// requirement: an intervening `FocusOut` processed on a yield is this
  /// codebase's own most common partial-edit data-loss shape).
  private func performDeleteAndCommit(
    offsetFromCursor: Int32, characterCount: UInt32, text: String
  ) {
    guard let objectPath = engineState.withLock({ $0.currentObjectPath }) else {
      // Cannot happen in practice — `FocusIn` only ever arrives on an
      // engine object `CreateEngine` already allocated a path for — but
      // this must never force-unwrap; an impossible-in-practice missing
      // path degrades to a logged no-op, never a crash.
      Self.logger.error("performDeleteAndCommit: no engine object path recorded despite FocusIn")
      return
    }
    registrationConnection.send(
      IBusRequests.deleteSurroundingText(
        offsetFromCursor: offsetFromCursor, characterCount: characterCount,
        objectPath: objectPath, serial: registrationConnection.allocateSerial()))
    registrationConnection.send(
      IBusRequests.commitText(
        IBusText(text: text), objectPath: objectPath,
        serial: registrationConnection.allocateSerial()))
  }

  private func queryGlobalEngineName() -> String? {
    guard
      let reply = callConnection.call(IBusRequests.getGlobalEngine(serial: 4), timeout: callTimeout)
    else { return nil }
    return IBusResponses.parseGetGlobalEngineReply(reply) ?? Self.fallbackEngineName
  }

  private func restoreGlobalEngine(to name: String) -> Bool {
    guard
      let reply = callConnection.call(
        IBusRequests.setGlobalEngine(name: name, serial: 5), timeout: callTimeout)
    else { return false }
    return IBusResponses.isSuccessReply(reply)
  }
}
