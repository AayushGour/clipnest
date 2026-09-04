// SelfPasteRaceScenario.swift
//
// T-STRESS1 dimension 4 (original finding) + T-HANG2 (fix verification,
// 2026-09-03). ORIGINAL finding: production armed suppression via
// `ClipboardMonitor.ignore(changeCount:)` only after `Paster.paste(...)`
// FULLY returned — i.e. after the pasteboard write, THEN `synthesisDelay`
// (real `Task.sleep`, default 40ms), THEN focus re-verification and the
// synthesized keystroke. That left a 40ms+ write-to-arm window the real
// ~0.4s poll `Timer` could and did land inside (quantified below: 18/18
// raced at 5-42ms). FIX: `Paster.paste` now takes an `onPasteboardWrite`
// callback invoked immediately after the write, before `synthesisDelay`'s
// sleep even starts (see `Paster.paste`'s and `PickerViewModel+Paste
// .performPaste`'s doc comments) — `raceTrial` below mirrors THAT ordering
// now, not the original buggy one.
//
// Each trial runs ONE continuous background task that mirrors production's
// current sequence exactly (write -> onPasteboardWrite/ignore(changeCount)
// -> sleep(synthesisDelay) -> verify/synthesize) while `checkNow()` polls
// concurrently at a swept offset — so "self-captured" directly measures
// whether that offset landed inside the real write-to-arm window, not an
// artificial "suppression never armed at all" strawman. Offsets swept here
// are deliberately much tighter than the original run (which swept up to
// the ~40ms `synthesisDelay` boundary) — post-fix, the window is expected to
// be on the order of a single `@MainActor` hop, not 40ms.
//
// This scenario uses REAL `Task.sleep`/wall-clock timing (not a fake clock)
// deliberately: coding-standards.md's "no real timers" rule is scoped to
// `ClipnestCoreTests` (the CI-facing, deterministic suite) — reproducing an
// honest-to-goodness async scheduling race needs real timing, which is
// exactly why this lives in the standalone harness instead.
import ClipnestCore
import Foundation

struct RaceOffsetOutcome {
  let offsetMs: Double
  let selfCaptured: Bool
}

struct SelfPasteRaceResult {
  let textOutcomes: [RaceOffsetOutcome]
  let imageOutcomes: [RaceOffsetOutcome]
  let imageRaceProducedDistinctContentHash: Bool
  let synthesisDelayMs: Double
}

@MainActor
func runSelfPasteRaceScenario(
  images: [RealBlobFixtures.ImageFixture], repeatsPerOffset: Int = 3
) async throws -> SelfPasteRaceResult {
  let env = try makeStressEnvironment(label: "self-paste-race")
  defer { try? FileManager.default.removeItem(at: env.root) }

  let pasteboard = FakePasteboard()
  let target = FrontmostAppRef(bundleID: "com.example.target", processIdentifier: 4242)
  let synthesisDelay = Paster.defaultSynthesisDelay
  let synthesisDelayMs =
    Double(synthesisDelay.components.seconds) * 1000 + Double(synthesisDelay.components.attoseconds)
    / 1e15

  let paster = Paster(
    pasteboard: pasteboard,
    eventSynthesizer: FakeEventSynthesizer(),
    isAccessibilityGranted: { true },
    synthesisDelay: synthesisDelay,
    frontmostAppProvider: FakeFrontmostAppReferenceProvider(target)
  )

  let monitor = ClipboardMonitor(
    store: env.store,
    reader: PasteboardReader(),
    blobStore: env.blobStore,
    pasteboard: pasteboard,
    frontmostApplicationProvider: FakeFrontmostApplicationProvider(
      bundleID: "com.example.stress", appName: "StressSource"),
    captureEnabledProvider: { true },
    textRecognitionEnabledProvider: { false }
  )

  // T-HANG2 fix verification: the old sweep straddled the ~40ms
  // `synthesisDelay` boundary because that's how wide the write-to-arm
  // window used to be. Post-fix, `onPasteboardWrite` arms suppression
  // before `synthesisDelay`'s sleep even starts, so the only remaining
  // window is a single `@MainActor` hop — sub-millisecond in the common
  // case. This sweep stays sub-millisecond-to-low-single-digit-ms
  // (0/0.1/0.5/1/2/5ms) to see whether that hop is ever actually wide
  // enough for the 0.4s poll to land inside it, plus the original 40ms/80ms
  // points kept as a sanity check that far-out offsets still never race
  // (unchanged expectation either way).
  let offsetsMs: [Double] = [
    0, 0.02, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 1, 1.5, 2, 3, 5, 8, 12, 20, 40, 80,
  ]  // T-HANG3: widened sweep + finer near-0 resolution vs the original 8-point check.

  var textOutcomes: [RaceOffsetOutcome] = []
  for offsetMs in offsetsMs {
    for _ in 0..<repeatsPerOffset {
      let outcome = try await raceTrial(
        content: .text("pasted-text-\(UUID().uuidString)"), offsetMs: offsetMs,
        store: env.store, monitor: monitor, paster: paster, pasteboard: pasteboard, target: target)
      textOutcomes.append(outcome)
    }
  }

  // Image variant: a raced self-capture doesn't just bump the same row
  // (dedup by contentHash) the way a raced TEXT paste does — Paster
  // normalizes the pasted bytes to TIFF via decode+re-encode
  // (`normalizedToTIFF`) before writing, which is not guaranteed
  // byte-identical to the original capture. Confirms whether that produces
  // a genuinely NEW row (not just a reordered one) when raced.
  var imageOutcomes: [RaceOffsetOutcome] = []
  var imageRaceProducedDistinctHash = false
  if let fixture = images.first(where: { $0.byteCount > 10_000 }) ?? images.first {
    let originalHash = BlobStore.contentHash(of: fixture.bytes)
    // T-HANG2: `.image` content's write is preceded by an internal
    // `Task.detached` decode/re-encode suspension (see `Paster.paste`'s
    // `.image` case) — swept slightly wider than the text sweep to account
    // for that extra hop, still nowhere near the old 40ms+ window.
    for offsetMs in [
      0.0, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 12.0, 20.0, 40.0, 80.0,
    ] {  // T-HANG3: widened, matches the TEXT sweep density.
      for _ in 0..<repeatsPerOffset {
        let outcome = try await raceTrial(
          content: .image(fixture.bytes), offsetMs: offsetMs, store: env.store, monitor: monitor,
          paster: paster, pasteboard: pasteboard, target: target,
          onSelfCapturedItem: { item in
            if item.contentHash != originalHash { imageRaceProducedDistinctHash = true }
          })
        imageOutcomes.append(outcome)
      }
    }
  }

  return SelfPasteRaceResult(
    textOutcomes: textOutcomes, imageOutcomes: imageOutcomes,
    imageRaceProducedDistinctContentHash: imageRaceProducedDistinctHash,
    synthesisDelayMs: synthesisDelayMs)
}

/// Runs one trial of the production paste sequence as a single background
/// task — pasteboard write, THEN (T-HANG2 — see `Paster.paste`'s and
/// `PickerViewModel+Paste.performPaste`'s doc comments) `onPasteboardWrite`
/// fires immediately, arming `monitor.ignore(changeCount:)` BEFORE
/// `synthesisDelay`'s sleep/focus-reverification/synthesized keystroke —
/// exactly matching production's current (post-fix) ordering — while
/// `checkNow()` polls concurrently after waiting `offsetMs`, simulating the
/// real 0.4s poll `Timer` landing at that instant. `selfCaptured == true`
/// means the poll observed the pasteboard's new content BEFORE the
/// background task's `onPasteboardWrite` callback had armed suppression — a
/// genuine reproduction of the race, not a strawman "suppression never
/// armed" case.
@MainActor
private func raceTrial(
  content: PasteContent, offsetMs: Double, store: any ClipStore, monitor: ClipboardMonitor,
  paster: Paster, pasteboard: FakePasteboard, target: FrontmostAppRef,
  onSelfCapturedItem: ((ClipItem) -> Void)? = nil
) async throws -> RaceOffsetOutcome {
  try? await store.clearHistory()

  pasteboard.simulateTextCopy("baseline-\(UUID().uuidString)")
  _ = await monitor.checkNow()

  let pasteAndArmTask = Task { @MainActor in
    try? await paster.paste(
      content, targetingFrontmostApp: target,
      onPasteboardWrite: { changeCount in
        // T-HANG2, exact production ordering (`performPaste`): fires
        // immediately after the write, before `synthesisDelay`'s sleep.
        monitor.ignore(changeCount: changeCount)
      })
  }

  if offsetMs > 0 {
    try? await Task.sleep(for: .seconds(offsetMs / 1000))
  }
  let captured = await monitor.checkNow()
  if let captured, let onSelfCapturedItem {
    onSelfCapturedItem(captured)
  }
  await pasteAndArmTask.value
  return RaceOffsetOutcome(offsetMs: offsetMs, selfCaptured: captured != nil)
}
