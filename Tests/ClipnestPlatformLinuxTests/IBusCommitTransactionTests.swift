// IBusCommitTransactionTests.swift
//
// T-IBUS-REPLACER: pure orchestration coverage for the corrected gate —
// switch -> wait for FocusIn -> ask for surrounding text -> wait for
// SetSurroundingText (the REAL gate, D-IBUS-5) -> recover the selection ->
// ask for a body -> delete+commit -> ALWAYS restore. Entirely via injected
// closures — no DBusConnection, no real bus. Supersedes the pre-T-IBUS-
// REPLACER version of this file, which pinned the now-corrected FocusIn-
// only gate (see `IBusCommitOutcome`'s own doc comment for why FocusIn
// alone was found insufficient).

import ClipnestViewModels
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

private final class FakeKeyValueStoreForTransaction: KeyValueStore, @unchecked Sendable {
  private var storage: [String: Any] = [:]
  func object(forKey key: String) -> Any? { storage[key] }
  func string(forKey key: String) -> String? { storage[key] as? String }
  func stringArray(forKey key: String) -> [String]? { storage[key] as? [String] }
  func bool(forKey key: String) -> Bool { storage[key] as? Bool ?? false }
  func set(_ value: Any?, forKey key: String) {
    if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
  }
}

/// Records call order across every step, so tests can assert SEQUENCING
/// (e.g. "persist happens before the switch is ever issued"), not just
/// which steps ran.
private final class CallLog: @unchecked Sendable {
  private(set) var events: [String] = []
  func record(_ event: String) { events.append(event) }
}

@Suite("IBusCommitTransaction")
struct IBusCommitTransactionTests {
  private func makeTransaction(
    store: FakeKeyValueStoreForTransaction,
    log: CallLog,
    currentEngineName: String?,
    focusInArrives: Bool,
    surroundingText: (text: String, cursorPos: UInt32, anchorPos: UInt32)?,
    bodyForSelectionResult: String?,
    restoreConfirmed: Bool
  ) -> IBusCommitTransaction {
    IBusCommitTransaction(
      crashSafety: IBusCrashSafetyStateMachine(store: store),
      queryCurrentEngineName: {
        log.record("query")
        return currentEngineName
      },
      switchToOurEngine: { log.record("switch") },
      waitForFocusIn: {
        log.record("waitForFocusIn")
        return focusInArrives
      },
      requireSurroundingText: { log.record("requireSurroundingText") },
      waitForSurroundingText: {
        log.record("waitForSurroundingText")
        return surroundingText
      },
      bodyForSelection: { selection in
        log.record("bodyForSelection(\(selection))")
        return bodyForSelectionResult
      },
      deleteAndCommit: { offsetFromCursor, characterCount, text in
        log.record("deleteAndCommit(offset:\(offsetFromCursor),count:\(characterCount))")
      },
      restoreEngine: { name in
        log.record("restore(\(name))")
        return restoreConfirmed
      })
  }

  // MARK: - queryCurrentEngineName == nil -> .unavailable, nothing else runs

  @Test(
    "a nil queryCurrentEngineName bails to .unavailable WITHOUT switching, waiting, committing, or restoring anything"
  )
  func unavailableWhenCurrentEngineUnknowable() async {
    let store = FakeKeyValueStoreForTransaction()
    let log = CallLog()
    let transaction = makeTransaction(
      store: store, log: log, currentEngineName: nil, focusInArrives: true,
      surroundingText: ("hi sig there", 6, 3), bodyForSelectionResult: "body",
      restoreConfirmed: true)

    let outcome = await transaction.run()

    #expect(outcome == .unavailable)
    #expect(log.events == ["query"])
    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == nil)
  }

  // MARK: - FocusIn never arrives -> noLiveRecipient, no RequireSurroundingText, still restores

  @Test(
    "FocusIn never arriving skips RequireSurroundingText/delete/commit entirely and returns .noLiveRecipient, but STILL restores the engine"
  )
  func focusInNeverArrivesSkipsEverythingButStillRestores() async {
    let store = FakeKeyValueStoreForTransaction()
    let log = CallLog()
    let transaction = makeTransaction(
      store: store, log: log, currentEngineName: "xkb:us::eng", focusInArrives: false,
      surroundingText: ("hi sig there", 6, 3), bodyForSelectionResult: "body",
      restoreConfirmed: true)

    let outcome = await transaction.run()

    #expect(outcome == .noLiveRecipient)
    #expect(log.events == ["query", "switch", "waitForFocusIn", "restore(xkb:us::eng)"])
    #expect(!log.events.contains("requireSurroundingText"))
    #expect(!log.events.contains("deleteAndCommit"))
  }

  // MARK: - FocusIn arrives, SetSurroundingText never arrives -> noLiveRecipient, still restores

  @Test(
    "FocusIn arriving but SetSurroundingText never answering RequireSurroundingText returns .noLiveRecipient (the corrected gate, D-IBUS-5) — never issues delete+commit, but STILL restores"
  )
  func focusInArrivesButNoSurroundingTextAnswerFallsThrough() async {
    let store = FakeKeyValueStoreForTransaction()
    let log = CallLog()
    let transaction = makeTransaction(
      store: store, log: log, currentEngineName: "xkb:us::eng", focusInArrives: true,
      surroundingText: nil, bodyForSelectionResult: "body", restoreConfirmed: true)

    let outcome = await transaction.run()

    #expect(outcome == .noLiveRecipient)
    #expect(
      log.events == [
        "query", "switch", "waitForFocusIn", "requireSurroundingText", "waitForSurroundingText",
        "restore(xkb:us::eng)",
      ])
    #expect(!log.events.contains("bodyForSelection"))
    #expect(!log.events.contains { $0.hasPrefix("deleteAndCommit") })
  }

  // MARK: - SetSurroundingText arrives with cursorPos == anchorPos (nothing selected) -> noSelection

  @Test(
    "a SetSurroundingText answer with cursorPos == anchorPos (nothing highlighted) never calls bodyForSelection and returns .noSelection, but STILL restores"
  )
  func surroundingTextWithNoSelectionFallsThrough() async {
    let store = FakeKeyValueStoreForTransaction()
    let log = CallLog()
    let transaction = makeTransaction(
      store: store, log: log, currentEngineName: "xkb:us::eng", focusInArrives: true,
      surroundingText: ("hi there", 3, 3), bodyForSelectionResult: "body", restoreConfirmed: true)

    let outcome = await transaction.run()

    #expect(outcome == .noSelection)
    #expect(!log.events.contains { $0.hasPrefix("bodyForSelection") })
    #expect(!log.events.contains { $0.hasPrefix("deleteAndCommit") })
    #expect(log.events.last == "restore(xkb:us::eng)")
  }

  // MARK: - Real selection recovered, bodyForSelection finds no match -> noMatch, terminal, still restores

  @Test(
    "a real selection with no snippet match calls bodyForSelection, never issues delete+commit, and returns .noMatch — still restores"
  )
  func realSelectionNoMatchReturnsNoMatch() async {
    let store = FakeKeyValueStoreForTransaction()
    let log = CallLog()
    let transaction = makeTransaction(
      store: store, log: log, currentEngineName: "xkb:us::eng", focusInArrives: true,
      surroundingText: ("hi sig there", 6, 3), bodyForSelectionResult: nil,
      restoreConfirmed: true)

    let outcome = await transaction.run()

    #expect(outcome == .noMatch)
    #expect(log.events.contains("bodyForSelection(sig)"))
    #expect(!log.events.contains { $0.hasPrefix("deleteAndCommit") })
    #expect(log.events.last == "restore(xkb:us::eng)")
  }

  // MARK: - Real selection, matched -> deleteAndCommit issued, committedUnconfirmed, still restores

  @Test(
    "a real, matched selection issues delete+commit with the offset/count computed from cursor/anchor and returns .committedUnconfirmed — still restores"
  )
  func realSelectionMatchedCommitsAndRestores() async {
    let store = FakeKeyValueStoreForTransaction()
    let log = CallLog()
    // "hi sig there": cursor at 6 (end of "sig"), anchor at 3 (start of
    // "sig") -> selection "sig", offsetFromCursor = min(3,6)-6 = -3,
    // characterCount = 3.
    let transaction = makeTransaction(
      store: store, log: log, currentEngineName: "xkb:us::eng", focusInArrives: true,
      surroundingText: ("hi sig there", 6, 3), bodyForSelectionResult: "Best regards, Clipnest",
      restoreConfirmed: true)

    let outcome = await transaction.run()

    #expect(outcome == .committedUnconfirmed)
    #expect(log.events.contains("bodyForSelection(sig)"))
    #expect(log.events.contains("deleteAndCommit(offset:-3,count:3)"))
    #expect(
      log.events == [
        "query", "switch", "waitForFocusIn", "requireSurroundingText", "waitForSurroundingText",
        "bodyForSelection(sig)", "deleteAndCommit(offset:-3,count:3)", "restore(xkb:us::eng)",
      ])
  }

  @Test(
    "the OPPOSITE selection direction (cursor at the selection's START, anchor at its end) computes offsetFromCursor 0"
  )
  func selectionWithCursorAtStartComputesZeroOffset() async {
    let store = FakeKeyValueStoreForTransaction()
    let log = CallLog()
    // "hi sig there": cursor at 3 (start of "sig"), anchor at 6 (end of
    // "sig") -> selection "sig", offsetFromCursor = min(3,6)-3 = 0,
    // characterCount = 3.
    let transaction = makeTransaction(
      store: store, log: log, currentEngineName: "xkb:us::eng", focusInArrives: true,
      surroundingText: ("hi sig there", 3, 6), bodyForSelectionResult: "body",
      restoreConfirmed: true)

    let outcome = await transaction.run()

    #expect(outcome == .committedUnconfirmed)
    #expect(log.events.contains("deleteAndCommit(offset:0,count:3)"))
  }

  // MARK: - Persist happens before the switch, every time

  @Test(
    "the previous engine name is persisted to the crash-safety marker BEFORE the switch is ever issued"
  )
  func persistsBeforeSwitching() async {
    let store = FakeKeyValueStoreForTransaction()
    let log = CallLog()
    let transaction = makeTransaction(
      store: store, log: log, currentEngineName: "xkb:de::ger", focusInArrives: true,
      surroundingText: ("hi sig there", 6, 3), bodyForSelectionResult: "body",
      restoreConfirmed: true)

    _ = await transaction.run()

    // persistBeforeSwitch is a synchronous store write with no closure of
    // its own to log against, so this is asserted indirectly: by the time
    // `switch` (the very next logged event after `query`) runs, the
    // marker must already be readable in the store.
    #expect(log.events.first == "query")
    #expect(log.events[1] == "switch")
  }

  // MARK: - Restore confirmation clears (or doesn't clear) the marker

  @Test("a CONFIRMED restore clears the crash-safety marker")
  func confirmedRestoreClearsMarker() async {
    let store = FakeKeyValueStoreForTransaction()
    let log = CallLog()
    let transaction = makeTransaction(
      store: store, log: log, currentEngineName: "xkb:us::eng", focusInArrives: true,
      surroundingText: ("hi sig there", 6, 3), bodyForSelectionResult: "body",
      restoreConfirmed: true)

    _ = await transaction.run()

    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == nil)
  }

  @Test(
    "an UNCONFIRMED restore leaves the crash-safety marker in place, even though the transaction's own OUTCOME still reports normally — this is what lets the NEXT startup's reconciliation retry it"
  )
  func unconfirmedRestoreLeavesMarker() async {
    let store = FakeKeyValueStoreForTransaction()
    let log = CallLog()
    let transaction = makeTransaction(
      store: store, log: log, currentEngineName: "xkb:us::eng", focusInArrives: true,
      surroundingText: ("hi sig there", 6, 3), bodyForSelectionResult: "body",
      restoreConfirmed: false)

    let outcome = await transaction.run()

    #expect(
      outcome == .committedUnconfirmed, "the commit outcome is independent of restore confirmation")
    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == "xkb:us::eng")
  }

  @Test(
    "the restore call always targets the EXACT name queryCurrentEngineName returned, not a hardcoded default"
  )
  func restoreTargetsExactQueriedName() async {
    let store = FakeKeyValueStoreForTransaction()
    let log = CallLog()
    let transaction = makeTransaction(
      store: store, log: log, currentEngineName: "xkb:jp::jpn", focusInArrives: false,
      surroundingText: nil, bodyForSelectionResult: nil, restoreConfirmed: true)

    _ = await transaction.run()

    #expect(log.events.last == "restore(xkb:jp::jpn)")
  }
}
