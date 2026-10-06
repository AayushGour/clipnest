/// OCRTier.swift
///
/// The CPU-adaptive tier that ONNX Runtime PP-OCRv5 inference runs at on Linux.
/// Never a user-facing setting — the tier is computed from `MachineCapacity`
/// by `OCRTierSelector`, composing machine resources with the user's
/// `TextRecognitionQuality` choice (fast/accurate). See `OCRTierSelector`'s
/// doc comments for the full algorithm.
///
/// Tiers increase computational demand and inference quality:
/// - `.minimal`: 1 thread, small detection input, batch size 1, no orientation
///   classifier. Runs on low-power, battery, or cgroup-limited machines.
/// - `.balanced`: 2 threads, medium detection input, batch size 4, orientation
///   classifier enabled. The typical tier on modern multi-core laptops.
/// - `.performance`: 4 threads, large detection input, batch size 8,
///   orientation classifier enabled. Requires high-end hardware and available
///   memory.

public enum OCRTier: String, CaseIterable, Sendable, Comparable {
  case minimal
  case balanced
  case performance

  /// Ranking for `Comparable` conformance. `minimal` < `balanced` <
  /// `performance`. Needed so the tier selector can clamp/step tiers
  /// (e.g., "never exceed `.balanced` on battery").
  private var rank: Int {
    switch self {
    case .minimal:
      return 0
    case .balanced:
      return 1
    case .performance:
      return 2
    }
  }

  /// Implements `Comparable` ordering: `.minimal` < `.balanced` <
  /// `.performance`.
  public static func < (lhs: OCRTier, rhs: OCRTier) -> Bool {
    lhs.rank < rhs.rank
  }
}

/// Configuration parameters for ONNX Runtime PP-OCRv5 inference at a given
/// `OCRTier`. All values are hand-tuned defaults (not yet measured on real
/// hardware — see the constant definitions in `OCRTierSelector` for
/// justifications and caveats).
public struct OCRTierConfiguration: Sendable, Equatable {
  /// Which `OCRTier` this configuration was produced for — kept as its own
  /// stored field (not just implied by the numbers below) so a caller
  /// (metadata-only logging, a settings UI, a test assertion) can read back
  /// "which tier did we pick" without re-deriving it from the individual
  /// values.
  public let tier: OCRTier

  /// Number of threads for ONNX Runtime's intra-op parallelism (operator-level
  /// thread pool size). Higher values use more CPU but may improve latency
  /// on multi-core machines. Balanced against memory/power budget.
  public let intraOpNumThreads: Int

  /// Long side of the detection model's input image (pixels). Smaller values
  /// run faster but may miss small text; larger values are more thorough but
  /// slower and more memory-intensive. PaddleOCR's own detector commonly
  /// defaults to 960.
  public let detectionInputLongSide: Int

  /// Batch size for the text recognition model. Larger batches amortize
  /// per-image overhead but consume proportionally more memory.
  public let recognitionBatchSize: Int

  /// Whether to run the orientation classifier on detected text lines.
  /// Improves accuracy on rotated/skewed images but adds latency.
  public let runsOrientationClassifier: Bool

  /// Queue depth for how many images can be buffered waiting for inference.
  /// Higher values allow more pipelining but use more memory and increase
  /// worst-case latency.
  public let queueDepth: Int

  public init(
    tier: OCRTier,
    intraOpNumThreads: Int,
    detectionInputLongSide: Int,
    recognitionBatchSize: Int,
    runsOrientationClassifier: Bool,
    queueDepth: Int
  ) {
    self.tier = tier
    self.intraOpNumThreads = intraOpNumThreads
    self.detectionInputLongSide = detectionInputLongSide
    self.recognitionBatchSize = recognitionBatchSize
    self.runsOrientationClassifier = runsOrientationClassifier
    self.queueDepth = queueDepth
  }
}
