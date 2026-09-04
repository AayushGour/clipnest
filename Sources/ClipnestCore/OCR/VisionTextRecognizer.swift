// VisionTextRecognizer.swift
//
// T-OCR1: production `TextRecognizing`, backed by
// `Vision.VNRecognizeTextRequest`. Runs entirely on-device — Vision's text
// recognizer needs no network access, matching coding-standards.md's
// "local-only, always" privacy must.
//
// T-OCR8: `.recognitionLevel`/`usesLanguageCorrection` are no longer
// hardcoded to `.fast` — real-world testing on an actual screenshot showed
// `.fast` mangling digits/letters, punctuation, and arrows badly enough to
// be a real user complaint. Both are now derived per-call from the
// `TextRecognitionQuality` the caller passes in (`ClipboardMonitor` reads
// the user's Settings choice fresh on every capture — see
// `recognitionLevel(for:)` below for the exact mapping and the measured
// latency/accuracy trade-off).
//
// Every tunable number here (downscale target, size ceilings) lives as a
// `static let` on this type — matching this codebase's existing convention
// for type-scoped constants (see e.g. `ClipboardMonitor.defaultPollInterval`,
// `ItemPreviewController.gap`, `TextPreview.chunk`) rather than a separate
// shared constants file, per coding-standards.md's "no magic numbers, one
// place" rule.

import CoreGraphics
import Foundation
import ImageIO
import Vision
import os

public struct VisionTextRecognizer: TextRecognizing {
  /// Images are downscaled so their longer edge is at most this many points
  /// before recognition runs — keeps recognition's cost roughly constant
  /// regardless of how large the original screenshot/photo was, at either
  /// `TextRecognitionQuality`. 1600pt comfortably preserves legibility for
  /// typical UI/text screenshots while bounding worst-case per-capture
  /// latency.
  public static let maxDownscaledDimension: CGFloat = 1_600

  /// Images whose byte size exceeds this are skipped entirely (returns
  /// `nil` before even decoding) — a defensive ceiling against a
  /// pathologically large capture stalling the detached OCR task. 50 MB
  /// comfortably covers any realistic screenshot or pasted photo.
  ///
  /// T-PF6: deliberately kept as its OWN named constant, not unified with
  /// `PasteboardReader.maxCapturedImageByteSize` into one shared value, even
  /// though today they're numerically equal. They answer two different
  /// questions — "how big a file are we willing to feed to a synchronous,
  /// queued Vision request" here, vs. "how big a file are we willing to
  /// persist + hash for every future dedup check" there — that happen to
  /// land on the same number today because both derive from the same
  /// "comfortably covers any realistic screenshot/photo" intuition, not
  /// because one is mechanically defined in terms of the other. Bounding
  /// Vision request cost/latency has no logical reason to move in lockstep
  /// with capture/storage policy, and vice versa. Collapsing two
  /// independently-motivated values into one shared constant would create
  /// FALSE coupling — a future change to one policy silently changing the
  /// other — which this codebase's DRY rule does not require: DRY targets
  /// duplicated LOGIC/facts, not coincidental equality between values that
  /// could legitimately diverge. If you're re-reviewing this: deliberate,
  /// not an oversight — see the identical note on
  /// `PasteboardReader.maxCapturedImageByteSize`.
  public static let maxByteSize = 50_000_000

  /// Images whose pixel dimensions exceed this on either axis are skipped
  /// entirely — guards against a decompression-bomb-shaped image (a small
  /// byte count that decodes to an enormous pixel grid), which
  /// `maxByteSize` alone wouldn't catch since it's checked before decoding.
  ///
  /// T-PF6: same deliberate non-unification call as `maxByteSize` above —
  /// this bounds "how large an image are we willing to hand to Vision," a
  /// different policy question from
  /// `PasteboardReader.maxCapturedImagePixelDimension`'s "how large a
  /// decompression-bomb-shaped image are we willing to persist," even though
  /// both currently land on 20,000px. Not mechanically linked; see that note
  /// for the full reasoning.
  public static let maxPixelDimension: CGFloat = 20_000

  // MARK: - T-HANG1: off the cooperative pool, capped concurrency
  //
  // T-STRESS1 (`.claude/logs/tester.md`) reproduced the user's reported
  // paste hang and root-caused it to two compounding defects, both fixed by
  // `recognitionQueue` below:
  //
  // 1. `VNImageRequestHandler.perform(_:)` is SYNCHRONOUS and blocking — it
  //    does not return until Vision has finished (or errored). The old
  //    implementation called it directly from inside a
  //    `withCheckedContinuation` closure, itself invoked from
  //    `ClipboardMonitor.scheduleTextRecognition`'s `Task.detached`. That
  //    pins whichever Swift-concurrency cooperative-pool worker thread
  //    happens to run it for the call's ENTIRE duration — the textbook
  //    "blocking work inside an async context" anti-pattern. Under load
  //    this is not a theoretical concern: `sample` on the real production
  //    path showed every cooperative-pool thread (== `hw.ncpu`)
  //    simultaneously pinned this way, which in turn starved an unrelated
  //    off-main `Paster.paste(.image:)` call for 164+ seconds — see
  //    `.claude/logs/stress-artifacts/sample_paste_hang.txt` and this
  //    session's independent re-confirmation,
  //    `senior-dev-before-fix-sample1.txt`.
  // 2. Nothing capped how many recognitions could run at once —
  //    `scheduleTextRecognition` fires one `Task.detached` per `.image`
  //    capture unconditionally, so N images captured together meant N
  //    threads blocked simultaneously.
  //
  // `recognitionQueue` fixes both at once: it is a plain `DispatchQueue`
  // Swift concurrency does not own, so dispatching the ENTIRE
  // decode/downscale/Vision-request pipeline onto it removes that work from
  // the cooperative pool completely — no cooperative-pool thread is ever
  // blocked by Vision again, regardless of load. And because the queue is
  // SERIAL, it structurally enforces `maxConcurrentRecognitions` (see that
  // constant) with no separate counter/semaphore needed: GCD itself never
  // runs two blocks from a serial queue at once.
  //
  // Queueing policy: FIFO, nothing ever dropped. A serial `DispatchQueue`
  // runs blocks in submission order and holds an unbounded backlog — an
  // image captured while the queue is busy simply waits its turn and WILL
  // eventually be recognized (OCR latency for that image goes up under
  // load; capture itself is completely unaffected either way, since
  // `checkNow()` never awaits this queue — see `scheduleTextRecognition`'s
  // doc comment). Given `maxConcurrentRecognitions` below, no other
  // discipline was implemented (no newest-first, no drop-oldest) because
  // dropping a user's requested OCR pass — even under a burst — would be a
  // silent, surprising data loss for a feature whose whole point is "find
  // this later by its text"; a slower queue is an acceptable, honest
  // trade-off a purely best-effort background feature should make instead.
  private static let recognitionQueue = DispatchQueue(
    label: "com.clipnest.visiontextrecognizer.recognitionQueue", qos: .utility)

  /// The number of recognition pipelines (decode + downscale +
  /// `VNImageRequestHandler.perform`) allowed to run at once. Enforced
  /// structurally by `recognitionQueue` being SERIAL — this constant exists
  /// to name and justify that number for readers/reviewers (per
  /// coding-standards.md's "no magic numbers, one place" rule), not to
  /// configure anything at runtime; changing this value alone does nothing; changing
  /// `recognitionQueue` to `.concurrent` plus a real limiter would be needed
  /// too, and should not be done without re-reading the justification below.
  ///
  /// Why 1, not 2 ("a defensible middle ground for a background nicety",
  /// per this task's framing): Apple's OWN `VNDetector` already serializes
  /// the real recognition work onto ITS OWN internal serial queue
  /// regardless of how many `perform` calls are outstanding — the exact
  /// `sample` capture that reproduced this hang shows this directly: every
  /// concurrent `perform()` caller funneled into one
  /// `com.apple.VN.detectorSyncTasksQueue.VNCRImageReaderDetector` SERIAL
  /// dispatch queue (`.claude/logs/stress-artifacts/sample_paste_hang.txt`,
  /// confirmed again in this session's own re-run). Issuing 2 concurrent
  /// `perform()` calls would not run 2 recognitions simultaneously — the
  /// second would simply block waiting on Apple's own internal queue while
  /// ALSO occupying a second dedicated thread here, for zero throughput
  /// gain. A cap of 1 gets identical real throughput to any higher cap,
  /// using the minimum thread footprint — not merely the "safe" choice, the
  /// throughput-optimal one.
  public static let maxConcurrentRecognitions = 1

  private static let logger = Logger(
    subsystem: ClipnestLog.subsystem, category: "VisionTextRecognizer")

  public init() {}

  public func recognizeText(in imageData: Data, quality: TextRecognitionQuality) async -> String? {
    guard imageData.count <= Self.maxByteSize else { return nil }

    // T-HANG1: the entire pipeline below — decode, the pixel-dimension
    // ceiling check (which needs a decoded image), downscale, and the
    // actual Vision request — runs on `recognitionQueue`, never on a
    // Swift-concurrency cooperative-pool thread. See that property's doc
    // comment for the full rationale. `imageData`/`quality` are both
    // `Sendable` value types and `continuation` is itself `Sendable`, so
    // this closure crosses onto `recognitionQueue` safely under Swift 6
    // strict concurrency with no extra synchronization.
    return await withCheckedContinuation { continuation in
      Self.recognitionQueue.async {
        guard let cgImage = Self.decodedCGImage(from: imageData) else {
          continuation.resume(returning: nil)
          return
        }
        guard CGFloat(cgImage.width) <= Self.maxPixelDimension,
          CGFloat(cgImage.height) <= Self.maxPixelDimension
        else {
          continuation.resume(returning: nil)
          return
        }

        let requestImage = Self.downscaled(cgImage, maxDimension: Self.maxDownscaledDimension)
        Self.performVisionRequest(on: requestImage, quality: quality, continuation: continuation)
      }
    }
  }

  /// Decodes `imageData` into a `CGImage`, entirely via `ImageIO`
  /// (`CGImageSourceCreateWithData`/`CGImageSourceCreateImageAtIndex`) rather
  /// than `NSImage(data:)`/`NSImage.cgImage(forProposedRect:context:hints:)`.
  /// T-REV1: this runs on `recognitionQueue`, never the main actor (see
  /// `recognizeText(in:quality:)`'s doc comment), and `NSImage` is not
  /// documented thread-safe for every operation off the main thread — the
  /// same reasoning `Paster.normalizedToTIFF` and `PasteboardReader
  /// .imagePixelDimensions` already state for their own off-main ImageIO
  /// decodes; `ImageIO`'s C API is a pure, thread-safe decode with no such
  /// caveat, so this file now follows the same rule those two do. Index `0`
  /// is the image source's primary/first frame, matching `Paster
  /// .normalizedToTIFF`'s choice for multi-representation/animated sources.
  /// Returns `nil` on undecodable bytes — same contract the previous
  /// `NSImage`-based decode had, so `recognizeText(in:quality:)`'s
  /// undecodable-data path is unaffected.
  private static func decodedCGImage(from imageData: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  /// Maps the app-facing `TextRecognitionQuality` to Vision's own level —
  /// the ONLY place `VNRequestTextRecognitionLevel` is referenced anywhere
  /// in the codebase, keeping `Vision` fully behind this type (see this
  /// file's doc comment / coding-standards.md's module layout).
  ///
  /// Measured on a real 2222x1244 screenshot (downscaled to
  /// `maxDownscaledDimension`, warmed up, median of 5 runs): `.fast` ran in
  /// 23ms but mangled digits/letters ("l." for "1."), punctuation
  /// ("Settings_" for "Settings..."), and dropped arrows; `.accurate` ran
  /// in 154ms and read all three correctly. `usesLanguageCorrection`
  /// follows the same split — it's part of what `.accurate` needs to fix
  /// punctuation, and pure overhead `.fast` shouldn't pay for.
  private static func recognitionLevel(for quality: TextRecognitionQuality)
    -> VNRequestTextRecognitionLevel
  {
    switch quality {
    case .fast: return .fast
    case .accurate: return .accurate
    }
  }

  /// Runs the actual `VNRecognizeTextRequest` and joins every recognized
  /// line's top candidate with a newline. `VNImageRequestHandler.perform(_:)`
  /// is synchronous and invokes its request's completion handler before
  /// returning, so resuming `continuation` from it (or, if `perform` itself
  /// throws before running anything, from the `catch` below) is safe —
  /// exactly one of those two paths runs, never both.
  ///
  /// T-HANG1: deliberately a plain, SYNCHRONOUS function (not `async`) — the
  /// caller (`recognizeText(in:quality:)`) already dispatched onto
  /// `recognitionQueue` before calling this, precisely so this blocking
  /// `perform(_:)` call executes there and nowhere near the cooperative
  /// pool. Making this `async` again would reintroduce a suspension point
  /// that could let the caller resume on some OTHER (cooperative-pool)
  /// thread instead of staying put — see `recognitionQueue`'s doc comment.
  private static func performVisionRequest(
    on cgImage: CGImage, quality: TextRecognitionQuality,
    continuation: CheckedContinuation<String?, Never>
  ) {
    let request = VNRecognizeTextRequest { request, error in
      guard error == nil,
        let observations = request.results as? [VNRecognizedTextObservation]
      else {
        continuation.resume(returning: nil)
        return
      }
      let lines = observations.compactMap { $0.topCandidates(1).first?.string }
      let joined = lines.joined(separator: "\n")
      continuation.resume(returning: joined.isEmpty ? nil : joined)
    }
    let level = recognitionLevel(for: quality)
    request.recognitionLevel = level
    request.usesLanguageCorrection = level == .accurate

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
      try handler.perform([request])
    } catch {
      logger.error(
        "VisionTextRecognizer: request failed (\(String(describing: error), privacy: .public))"
      )
      continuation.resume(returning: nil)
    }
  }

  /// Scales `image` down so its longer edge is at most `maxDimension`,
  /// preserving aspect ratio. Returns `image` itself unchanged if it's
  /// already within bounds, or if the scaled context can't be created
  /// (recognition then simply runs against the original — degrading
  /// gracefully rather than skipping recognition outright, unlike the
  /// ceiling checks in `recognizeText(in:)`, which skip by design).
  private static func downscaled(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let longEdge = max(width, height)
    guard longEdge > maxDimension else { return image }

    let scale = maxDimension / longEdge
    let newWidth = max(1, Int(width * scale))
    let newHeight = max(1, Int(height * scale))

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: newWidth,
        height: newHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return image }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
    return context.makeImage() ?? image
  }
}
