// VisionTextRecognizerTests.swift
//
// T-OCR1: `VisionTextRecognizer` is the one production conformance to
// `TextRecognizing` that actually calls `Vision` — every other test in this
// suite (`ClipboardMonitorTests`'s OCR wiring cases) exercises
// `ClipboardMonitor` against a fake `TextRecognizing` instead, per
// coding-standards.md's testing rules and the same precedent
// `CGEventSynthesizer` already set (no real system-framework call asserted
// on for its *specific output* in CI; only its wiring is). What IS safe and
// deterministic to assert here, without depending on Vision actually
// finding text in a fixture image (it never will — these are blank/garbage
// bytes, not real screenshots): the byte/pixel-ceiling guards that skip
// recognition entirely, and that a well-formed-but-textless image round-
// trips to `nil` rather than throwing/crashing.

// P2-A (Linux port): this whole file is genuinely macOS-only — it tests
// `VisionTextRecognizer`, which is itself `#if os(macOS)` in ClipnestCore
// (see `Platform/macOS/VisionTextRecognizer.swift`) — so the whole file
// is gated the same way, rather than gating individual tests inside it.
#if os(macOS)
  import Foundation
  import Testing

  @testable import ClipnestCore

  @Suite("VisionTextRecognizer")
  struct VisionTextRecognizerTests {

    @Test("Images over the byte-size ceiling are skipped entirely — returns nil")
    func skipsImagesOverByteSizeCeiling() async {
      let recognizer = VisionTextRecognizer()
      let oversized = Data(repeating: 0, count: VisionTextRecognizer.maxByteSize + 1)

      let result = await recognizer.recognizeText(in: oversized, quality: .accurate)

      #expect(result == nil)
    }

    @Test("Garbage bytes that don't decode as an image return nil rather than crashing")
    func undecodableDataReturnsNil() async {
      let recognizer = VisionTextRecognizer()
      let garbage = Data("not an image".utf8)

      let result = await recognizer.recognizeText(in: garbage, quality: .accurate)

      #expect(result == nil)
    }

    @Test(
      "A tiny, well-formed image with no text returns nil at either quality (no crash, no false positive)"
    )
    func textlessImageReturnsNilAtEitherQuality() async {
      let recognizer = VisionTextRecognizer()
      let imageData = ImageFixtures.makeTinyImageData(width: 8, height: 8)

      // T-OCR8: both `TextRecognitionQuality` cases must round-trip through
      // the real `VNRecognizeTextRequest` cleanly — this is the one place a
      // real Vision call is exercised (see this file's doc comment), so it's
      // also the only place worth confirming `.fast` and `.accurate` both
      // reach Vision without throwing/crashing, even though asserting on
      // recognized *content* happens only via the fake in
      // `ClipboardMonitorTests`.
      for quality in TextRecognitionQuality.allCases {
        let result = await recognizer.recognizeText(in: imageData, quality: quality)
        #expect(result == nil)
      }
    }

    // MARK: - T-HANG1: many concurrent recognitions never starve the cooperative pool

    /// Regression test for the reproduced paste-hang (T-STRESS1 finding #1,
    /// independently re-confirmed this session — see `.claude/logs/senior-dev.md`
    /// and `.claude/logs/stress-artifacts/senior-dev-before-fix-sample1.txt`).
    ///
    /// An earlier version of this test measured "how many `recognizeText`
    /// calls are outstanding (submitted but not yet returned) at once" via an
    /// enter/exit actor tracker — the same shape `tools/stress-harness`'s
    /// `ConcurrencyTracker` uses. That metric turned out to be a poor proxy
    /// for the real bug once a queue exists: a call sitting queued (not yet
    /// dequeued) looks identical to a call genuinely executing — both are
    /// "outstanding" — so it could never distinguish "serialized" from
    /// "unbounded", and stayed red even against the fixed code. Deleted in
    /// favor of THIS test, which measures the actual observable symptom
    /// instead: does firing many recognitions starve OTHER, unrelated
    /// cooperative-pool work — exactly what made the real paste hang (a
    /// `Task.detached` inside `Paster.paste(.image:)`) unable to even be
    /// scheduled for 164+ seconds. Mirrors `PasterTests
    /// .imageDecodeDoesNotBlockTheCallingActor`'s "does a racing counter task
    /// get starved" shape, generalized from `@MainActor` to the cooperative
    /// pool.
    ///
    /// Watched this fail against the unfixed code before the production fix
    /// (`VisionTextRecognizer.recognitionQueue`) landed — pasted the exact
    /// failing numbers in `.claude/logs/senior-dev.md`. Both this test's
    /// `imageCount` (~2x this machine's core count) and quality (`.accurate`,
    /// the shipped default) are deliberately close to T-STRESS1's own
    /// repro shape (~15-20 images) rather than an artificially extreme count.
    @Test(
      "Many concurrent recognitions never starve an unrelated cooperative-pool task — regression for the reproduced paste hang"
    )
    func manyConcurrentRecognitionsDoNotStarveTheCooperativePool() async {
      let recognizer = VisionTextRecognizer()
      // A small real image — `.fast` recognition's per-call cost is
      // dominated by Vision/ANE request setup, not pixel count — so this
      // stays tiny purely to minimize per-call ImageIO decode cost, not
      // because size matters for reproducing the starvation.
      let imageData = ImageFixtures.makeTinyImageData(width: 40, height: 40)
      // Enough images to exceed this machine's cooperative-pool worker-thread
      // count (~`activeProcessorCount`), so the unfixed code — one
      // `Task.detached` blocking one cooperative-pool thread per image, no
      // cap — has every opportunity to pin the whole pool, matching how
      // `ClipboardMonitor.scheduleTextRecognition` actually dispatches OCR
      // work. No extra margin beyond the core count: T-STRESS1's real repro
      // (`.claude/logs/stress-artifacts/sample1.txt`) needed only ~10 images
      // on this same 10-core machine to pin every cooperative-pool thread.
      let imageCount = ProcessInfo.processInfo.activeProcessorCount

      // Sleep-based, NOT a hot `Task.yield()` spin: an earlier version of this
      // test used a tight `while !cancelled { tick(); await Task.yield() }`
      // loop, which is itself a CPU hog that competes aggressively for every
      // core — combined with `imageCount` blocking Vision calls it drove this
      // test to 90+ seconds even at a trivially small image size, on this
      // machine's real background load (other agents' processes). A
      // `Task.sleep`-paced heartbeat (mirrors `tools/stress-harness`'s own
      // `Heartbeat.swift`) is cheap and well-behaved, and still can't resume
      // promptly if the cooperative pool is genuinely starved — `Task.sleep`'s
      // continuation needs a free pool thread to resume on same as any other
      // suspended `Task`.
      actor GapTracker {
        private let clock = ContinuousClock()
        private var last = ContinuousClock.now
        private var worstGap: Duration = .zero

        func tick() {
          let now = clock.now
          worstGap = max(worstGap, now - last)
          last = now
        }

        func maxGapMs() -> Double {
          Double(worstGap.components.seconds) * 1000 + Double(worstGap.components.attoseconds)
            / 1e15
        }
      }
      let gaps = GapTracker()
      let heartbeatTask = Task.detached(priority: .utility) {
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(5))
          await gaps.tick()
        }
      }

      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<imageCount {
          group.addTask {
            _ = await recognizer.recognizeText(in: imageData, quality: .fast)
          }
        }
      }

      heartbeatTask.cancel()
      _ = await heartbeatTask.value

      let observedMaxGapMs = await gaps.maxGapMs()
      // Generous, not fragile: a healthy heartbeat's worst gap should stay in
      // the tens-of-ms range even under real machine noise. Against the
      // unfixed code this repeatedly came back in the SECONDS (the heartbeat
      // couldn't resume at all for long stretches while every cooperative-pool
      // thread sat blocked inside Vision) — see the pasted failing run in
      // senior-dev.md. 1000ms comfortably separates "healthy, just noisy" from
      // "the pool was starved," without chasing an exact number on a shared,
      // variably-loaded dev machine.
      #expect(observedMaxGapMs < 1000)
    }
  }
#endif
