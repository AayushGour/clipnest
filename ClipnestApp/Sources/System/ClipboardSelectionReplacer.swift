// ClipboardSelectionReplacer.swift
//
// The universal, works-in-any-app `SelectionReplacing` implementation used by
// `SnippetExpander`'s fallback path (when Accessibility can't read the
// selection — Electron/Chrome/Java apps). It drives synthesized Copy/Paste
// keystrokes (which every app supports) and snapshots + RESTORES the clipboard
// around the whole thing, so the user's clipboard ends up unchanged. Clipnest's
// own capture is suppressed for the duration via injected `beginSuppression`/
// `endSuppression` (wired to `ClipboardMonitor.pause()`/`ignore`+`resume` in
// `AppEnvironment`) so the transient copy/paste doesn't land in history.
//
// Posting `CGEvent` keystrokes requires Accessibility (same grant `Paster`
// already needs); without it the synthetic ⌘C is dropped, the pasteboard
// doesn't change, and this returns `.noSelection` (the expander then beeps).
//
// T-ELEC1 (2026-09): investigated a report that snippet expansion doesn't
// replace text in Electron apps (VS Code, Claude desktop). Real,
// instrumented reproduction against VS Code (a confirmed Electron app) —
// 7 trials, varying the ⌥⌘E modifier-hold duration (5-400ms), workspace
// load (bare scratch file vs. this repo open with extensions active), and
// selection size — found the copy phase landing at a consistent ~80ms
// (`modifierClearDelay` + one or two `copyWaitStep` polls), the paste
// settling correctly every time, and the clipboard restored byte-for-byte
// every time: none of the three suspect fixed delays below actually fired.
// See `SelectedTextAccessing.swift`'s T-ELEC1 note for the real, evidence-
// backed bug this investigation DID find (an `AXWebArea` false-positive
// selection read on Antigravity IDE, a different Electron app, that beeps
// before this file is ever reached at all).
//
// `modifierClearDelay` (60ms) is a fixed guess this project's own
// port-planning notes already flagged as a known-weak spot, recommending an
// OBSERVED-release poll instead (10ms step, 400ms ceiling) — that was
// implemented and tested here, then DELIBERATELY REVERTED: it introduced a
// reproducible ~400ms stall immediately after the Carbon hotkey (⌥⌘E)
// dispatch, even though a SEPARATE probe process confirmed the OS-level
// modifier flags had already cleared well before that — i.e. Clipnest's own
// poll wasn't observing the already-current state promptly right at that
// exact moment (root cause not fully isolated: possibly Carbon's hotkey
// event-dispatch briefly affecting how promptly a `Task.sleep` on the main
// actor resumes and re-checks, immediately after its own callback fires;
// the very next poll in this same call path, `waitForChange` below, runs at
// its normal ~15ms cadence, so whatever it is is transient and specific to
// the instant right after Carbon's dispatch). Given zero trials — 7 clean
// runs plus every trial in this file's own manual verification — ever
// showed the FIXED 60ms delay causing a real failure, shipping the observed
// -release poll's unexplained, reproducible latency cost on every single
// expansion was not justified by the evidence. Left as a disclosed
// follow-up rather than shipped blind or silently dropped.

import AppKit
import ClipnestCore
import CoreGraphics
import Foundation
import os

@MainActor
final class ClipboardSelectionReplacer: SelectionReplacing {
  /// Logged at `.notice` (persisted to the unified log — see
  /// `HotkeyManager.applyDeliveryMode`'s identical reasoning) so a real
  /// failure's phase/timing is answerable from a user's Mac via `log show`
  /// without asking them to reproduce live. Metadata only: elapsed
  /// durations, char counts, and booleans — never clipboard content.
  private static let logger = Logger(
    subsystem: ClipnestLog.subsystem, category: "ClipboardSelectionReplacer")

  private let pasteboard: NSPasteboard

  /// Called before the clipboard is borrowed (→ `ClipboardMonitor.pause()`),
  /// and after it's restored (→ ignore the restore's change + `resume()`), so
  /// the transient copy/paste is never captured into history. Default no-ops.
  var beginSuppression: () -> Void = {}
  var endSuppression: () -> Void = {}

  /// Carbon virtual keycodes (`kVK_ANSI_C` / `kVK_ANSI_V`).
  private static let cKey: CGKeyCode = 0x08
  private static let vKey: CGKeyCode = 0x09

  /// Let the user's ⌥⌘E modifiers clear before posting ⌘C, so the synthetic
  /// keystroke isn't merged with a still-held ⌥/⌘. See this file's header
  /// for why this stays a fixed delay rather than the observed-release poll
  /// the project's port-planning notes recommended.
  private static let modifierClearDelay = Duration.milliseconds(60)
  /// Poll step / ceiling while waiting for the frontmost app to write the
  /// copied selection to the pasteboard after ⌘C.
  private static let copyWaitStep = Duration.milliseconds(15)
  private static let copyMaxWait = Duration.milliseconds(500)
  /// Give the synthesized ⌘V time to land in the target app before the
  /// clipboard is restored out from under it.
  private static let pasteSettle = Duration.milliseconds(120)

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  func replaceSelection(bodyForSelection: (String) async -> String?) async
    -> SelectionReplaceResult
  {
    beginSuppression()
    let snapshot = snapshotClipboard()
    defer {
      restoreClipboard(snapshot)
      endSuppression()
    }

    let transactionStart = ContinuousClock.now
    try? await Task.sleep(for: Self.modifierClearDelay)

    let before = pasteboard.changeCount
    let copyPostedOK = postCommandKey(Self.cKey)
    let changed = await waitForChange(after: before)
    let copyElapsedMs = transactionStart.duration(to: .now).milliseconds
    guard copyPostedOK, changed else {
      // ⌘C produced no clipboard change → nothing selected (or Accessibility
      // not granted, so the keystroke was dropped).
      Self.logger.notice(
        """
        copy phase FAILED: posted=\(copyPostedOK, privacy: .public) \
        pasteboardChanged=\(changed, privacy: .public) \
        elapsedMs=\(copyElapsedMs, privacy: .public) -> .noSelection
        """)
      return .noSelection
    }
    Self.logger.notice("copy phase OK: elapsedMs=\(copyElapsedMs, privacy: .public)")

    let selection = pasteboard.string(forType: .string) ?? ""
    guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      Self.logger.notice("selection empty after trim -> .noSelection")
      return .noSelection
    }
    Self.logger.notice("selection captured: \(selection.count, privacy: .public) chars")

    guard let body = await bodyForSelection(selection) else {
      Self.logger.notice("no snippet keyword match -> .noMatch")
      return .noMatch
    }
    Self.logger.notice("keyword matched, body length=\(body.count, privacy: .public) chars")

    pasteboard.clearContents()
    pasteboard.setString(body, forType: .string)
    let pasteWriteChangeCount = pasteboard.changeCount
    let pastePostedOK = postCommandKey(Self.vKey)
    guard pastePostedOK else {
      Self.logger.notice("failed to post synthetic \u{2318}V -> .noMatch")
      return .noMatch
    }
    try? await Task.sleep(for: Self.pasteSettle)
    // Whether the target app ever actually READ the pasteboard before this
    // point restores it is not directly observable — `changeCount` only
    // tells us whether Clipnest's own write is still the most recent one,
    // not whether the target consumed it. Logged anyway: if `changeCount`
    // had already moved again by the time we get here, something else (not
    // the target's own read) touched the pasteboard mid-settle, which would
    // itself be a clue.
    let changeCountStillOurs = pasteboard.changeCount == pasteWriteChangeCount
    let totalElapsedMs = transactionStart.duration(to: .now).milliseconds
    Self.logger.notice(
      """
      paste settle elapsed: changeCountStillOurs=\(changeCountStillOurs, privacy: .public) \
      totalElapsedMs=\(totalElapsedMs, privacy: .public)
      """)
    return .replaced
  }

  /// Waits (polling) up to `copyMaxWait` for the pasteboard's change count to
  /// move past `before`. Returns whether it changed.
  private func waitForChange(after before: Int) async -> Bool {
    var waited = Duration.zero
    while waited < Self.copyMaxWait {
      if pasteboard.changeCount != before { return true }
      try? await Task.sleep(for: Self.copyWaitStep)
      waited += Self.copyWaitStep
    }
    return pasteboard.changeCount != before
  }

  /// Posts a ⌘-modified keystroke through the global HID event tap (targeting
  /// whatever app is frontmost — the app the user is working in). Returns
  /// `false` only if the events couldn't be created.
  ///
  /// Routed through `ClipnestCore`'s shared `SyntheticKeystroke` (rather than
  /// hand-rolling a `CGEventSource`/`CGEvent` pair here) so there is exactly
  /// ONE place that builds and posts synthetic modified keystrokes —
  /// `Paster`'s `CGEventSynthesizer` (picker paste, ⌘V) uses the same
  /// helper. That shared implementation also fixes two defects the old
  /// hand-rolled version here had: it used to build events from
  /// `.combinedSessionState`, which merges the user's currently
  /// physically-held modifiers (very likely still Option+Command, since this
  /// fires from ⌥⌘E) into the synthetic event; and it asserted Command purely
  /// via `.flags` with no bracketing keydown/keyup to explicitly return the
  /// modifier state to released.
  private func postCommandKey(_ key: CGKeyCode) -> Bool {
    SyntheticKeystroke.postCommandModified(key)
  }

  /// Copies the current pasteboard's items + all their type data so they can
  /// be written back verbatim by `restoreClipboard`.
  private func snapshotClipboard() -> [NSPasteboardItem] {
    (pasteboard.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) {
          copy.setData(data, forType: type)
        }
      }
      return copy
    }
  }

  private func restoreClipboard(_ items: [NSPasteboardItem]) {
    pasteboard.clearContents()
    if !items.isEmpty {
      pasteboard.writeObjects(items)
    }
  }
}

// `Duration` has no built-in millisecond accessor suitable for a plain log
// string — this converts via `.components` (seconds + attoseconds) rather
// than any string formatter, so it costs nothing measurable next to the
// CGEvent posts/sleeps it's timing.
extension Duration {
  fileprivate var milliseconds: Double {
    let c = components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1_000_000_000_000_000
  }
}
