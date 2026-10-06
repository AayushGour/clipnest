// OnnxTextRecognizer.swift
//
// P6-C (Linux OCR): production `TextRecognizing` for Linux, backed by
// ONNX Runtime CPU + PP-OCRv5 mobile — the Linux counterpart to
// `Sources/ClipnestCore/Platform/macOS/VisionTextRecognizer.swift`. Read
// that file first if you haven't; this type mirrors its structure,
// ceilings, and concurrency discipline deliberately, one-for-one where the
// two platforms' underlying engines allow it.
//
// Entirely on-device, exactly like the macOS implementation: PP-OCRv5's
// ~21.7MB of models + ~16MB of ONNX Runtime are vendored by the separate
// `clipnest-ocr` package (see `Package.swift`'s `COnnxRuntime` comment) —
// nothing is ever downloaded here, matching this product's "the only
// network traffic is a daily GitHub release check" privacy promise.
import ClipnestCore
import Dispatch
import Foundation

public struct OnnxTextRecognizer: TextRecognizing {

  /// Images whose byte size exceeds this are skipped entirely, checked
  /// BEFORE any decode attempt — same ceiling, same rationale, as
  /// `VisionTextRecognizer.maxByteSize` (see that constant's doc comment
  /// for the full "why its own named constant, not a shared one" reasoning,
  /// which applies identically across platforms).
  public static let maxByteSize = 50_000_000

  /// Images whose pixel dimensions exceed this on either axis are skipped.
  /// UNLIKE `VisionTextRecognizer` (which must fully decode via `ImageIO`
  /// before it can read `cgImage.width`/`height`), this check happens
  /// straight after `PNGDecoder.readHeader` — PNG's `IHDR` chunk carries
  /// width/height as its very first bytes, so this ceiling is enforced
  /// BEFORE the (potentially large) `IDAT`/DEFLATE payload is ever
  /// decompressed. Same numeric ceiling as `VisionTextRecognizer
  /// .maxPixelDimension` (20,000px) — this task's mandate to "preserve the
  /// existing ceilings."
  public static let maxPixelDimension = 20_000

  /// True when this machine can actually perform on-device OCR right now:
  /// `libonnxruntime.so.1` resolves via `dlopen` (`OrtRuntimeAvailability
  /// .isAvailable`) AND the PP-OCRv5 model files are installed at
  /// `StandardOCRModelLocator`'s expected path. `clipnest` only
  /// `Recommends` `clipnest-ocr` (see that package's description in
  /// `debian/control`), so a `--no-install-recommends` install genuinely
  /// lacks both. Settings surfaces this truthfully — see
  /// `SettingsWindow+History.swift`'s gating on this property — rather
  /// than showing a "Recognize text in copied images" toggle and Fast/
  /// Accurate quality picker that would silently no-op. Not injected via
  /// `modelLocator`/`capacityProber` above: those exist to make
  /// `recognizeText`'s BEHAVIOR testable without a real filesystem; this
  /// is a one-shot, whole-machine capability check the composition root
  /// reads once at launch, mirroring how `OrtRuntimeAvailability
  /// .isAvailable` itself is a bare static check, not an injectable
  /// dependency.
  public static var isAvailable: Bool {
    OrtRuntimeAvailability.isAvailable && StandardOCRModelLocator().locate() != nil
  }

  private let modelLocator: OCRModelLocating
  private let capacityProber: MachineCapacityProbing
  private let tierOverride: OCRTierOverride
  private let requestQueue: OCRRequestQueue

  /// `modelLocator`/`capacityProber`/`tierOverride` are injectable — tests
  /// can supply a locator that reports "no models installed" (verifying
  /// the graceful-`nil` path) or a fixed capacity/override to pin a
  /// specific tier deterministically, without touching a real filesystem
  /// or depending on the actual host machine's hardware. Mirrors this
  /// codebase's established injectable-dependency pattern (see
  /// `TextRecognizing.swift`'s own doc comment).
  public init(
    modelLocator: OCRModelLocating = StandardOCRModelLocator(),
    capacityProber: MachineCapacityProbing = LiveMachineCapacityProber(),
    tierOverride: OCRTierOverride = .automatic
  ) {
    self.modelLocator = modelLocator
    self.capacityProber = capacityProber
    self.tierOverride = tierOverride
    self.requestQueue = OCRRequestQueue(queue: OrtEnvironment.shared.queue)
  }

  public func recognizeText(in imageData: Data, quality: TextRecognitionQuality) async -> String? {
    guard imageData.count <= Self.maxByteSize else { return nil }

    // Degrades to `nil` gracefully whenever `libonnxruntime.so.1` isn't
    // installed on this machine (`clipnest` only `Recommends`
    // `clipnest-ocr`, which vendors it — see `OrtLibrary.swift`) — an
    // ordinary, expected "OCR unavailable" state, checked at RUNTIME via
    // `dlopen`, never a crash. See `OrtRuntimeAvailability.swift`'s doc
    // comment.
    guard OrtRuntimeAvailability.isAvailable else { return nil }
    guard let modelPaths = modelLocator.locate() else { return nil }

    let bytes = [UInt8](imageData)
    guard let header = PNGDecoder.readHeader(bytes) else { return nil }
    guard Self.isWithinPixelCeiling(width: header.width, height: header.height) else {
      return nil
    }

    let capacity = capacityProber.probe()
    let tier = OCRTierSelector.select(capacity: capacity, quality: quality, override: tierOverride)

    // T-HANG1 discipline (see `OrtEnvironment.swift`'s doc comment):
    // `requestQueue.enqueue` returns immediately — the actual (blocking)
    // pipeline call happens later, on `OrtEnvironment.shared.queue`, never
    // on this `async` call's cooperative-pool thread. `imageData`,
    // `modelPaths`, and `tier` are all `Sendable` value types, so the
    // `work`/`onDropped` closures capturing them (plus `continuation`,
    // itself `Sendable`) cross onto that queue safely under Swift 6 strict
    // concurrency, exactly like `VisionTextRecognizer.recognizeText`'s own
    // `withCheckedContinuation` + `recognitionQueue.async` pairing.
    return await withCheckedContinuation { continuation in
      requestQueue.enqueue(
        maxDepth: tier.queueDepth,
        work: {
          let result = OCRPipeline.run(bytes: bytes, modelPaths: modelPaths, tier: tier)
          continuation.resume(returning: result)
        },
        onDropped: {
          // Bounded-queue backpressure (see `OCRRequestQueue.swift`'s doc
          // comment): a dropped item resolves to `nil`, the SAME outcome
          // as "no text found" — `ClipboardMonitor` leaves `ocrText ==
          // nil`, and the existing `OCRBackfillCoordinator` retries later.
          continuation.resume(returning: nil)
        })
    }
  }

  /// The ceiling applies to EITHER axis independently, matching
  /// `VisionTextRecognizer.maxPixelDimension`'s own "either axis" wording.
  private static func isWithinPixelCeiling(width: Int, height: Int) -> Bool {
    width <= maxPixelDimension && height <= maxPixelDimension
  }
}
