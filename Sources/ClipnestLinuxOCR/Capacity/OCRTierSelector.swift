import ClipnestCore

/// Override mechanism for tier selection (for testing, advanced settings, or
/// manual override).
public enum OCRTierOverride: Sendable, Equatable {
  /// Use the automatic algorithm based on capacity and quality.
  case automatic
  /// Force a specific tier, bypassing all automatic logic.
  case forced(OCRTier)
}

/// Selects the appropriate `OCRTier` and its configuration based on the
/// machine's capacity and the user's requested text recognition quality.
///
/// The algorithm composes two independent decisions:
/// 1. **Capacity ceiling:** What is the heaviest tier this machine can safely
///    sustain? Computed from CPU cores (accounting for cgroup limits), available
///    RAM, AVX-2 support, and whether on battery.
/// 2. **Quality stepping:** Within that ceiling, does the user want `.fast` or
///    `.accurate`? `.accurate` uses the full ceiling; `.fast` steps one tier
///    down (never below `.minimal`). This mirrors the existing `TextRecognitionQuality`
///    pattern on macOS (see `VisionTextRecognizer.swift`), keeping the OCR
///    quality concept unified across platforms.
///
/// An explicit `.forced(tier)` override bypasses both and returns the tier
/// as-is (for test harnesses or future advanced settings).
public enum OCRTierSelector {
  // MARK: - Tier configurations (named constants, no magic numbers)

  /// Minimal tier: 1 thread, small input, batch size 1, no orientation
  /// classifier, queue depth 1. Runs on low-power, battery-constrained, or
  /// severely cgroup-limited machines. Sacrifice detail and latency for
  /// safety and stability.
  private static let minimalIntraOpNumThreads = 1
  private static let minimalDetectionInputLongSide = 640
  private static let minimalRecognitionBatchSize = 1
  private static let minimalRunsOrientationClassifier = false
  private static let minimalQueueDepth = 1

  /// Balanced tier: 2 threads, medium input (960 is PaddleOCR's own DB
  /// detector default), batch size 4, orientation classifier enabled, queue
  /// depth 3. The typical configuration on modern 2-4 core laptops with 4+GB
  /// available RAM. Good balance of speed and accuracy.
  private static let balancedIntraOpNumThreads = 2
  private static let balancedDetectionInputLongSide = 960
  private static let balancedRecognitionBatchSize = 4
  private static let balancedRunsOrientationClassifier = true
  private static let balancedQueueDepth = 3

  /// Performance tier: 4 threads, large input (1280 is the 2x step from 640),
  /// batch size 8, orientation classifier enabled, queue depth 6. Requires
  /// 4+ physical cores, 2GB+ available RAM, and AVX-2 support. Delivers
  /// highest accuracy and throughput on powerful machines.
  private static let performanceIntraOpNumThreads = 4
  private static let performanceDetectionInputLongSide = 1280
  private static let performanceRecognitionBatchSize = 8
  private static let performanceRunsOrientationClassifier = true
  private static let performanceQueueDepth = 6

  // MARK: - RAM/core thresholds (named constants)

  /// Minimum available RAM (MB) to sustain the `.balanced` tier. Below this,
  /// cap at `.minimal` even with plenty of cores. A resident detection + text
  /// recognition model pair costs ~120-200MB RSS alone, and overlaps with OS
  /// caches/other processes; 1GB is a safe floor for two-model load.
  private static let balancedRAMFloorMB = 1024

  /// Minimum available RAM (MB) to sustain the `.performance` tier. Below this,
  /// cap at `.balanced`. Performance-tier batching and thread pools require
  /// additional headroom; 2GB is conservative but necessary to avoid swapping.
  private static let performanceRAMFloorMB = 2048

  /// Minimum *physical* cores needed to leave the `.minimal` tier. 2 physical
  /// cores (possibly with hyperthreading to 4 logical) can safely run 2 ONNX
  /// Runtime threads without oversubscription.
  private static let balancedCoreFloor = 2

  /// Minimum *physical* cores needed to reach the `.performance` tier. 4
  /// physical cores allow safe allocation of 4 ONNX Runtime threads.
  private static let performanceCoreFloor = 4

  // MARK: - Public API

  /// Returns the configuration for a given tier (tier-to-parameters mapping).
  public static func configuration(for tier: OCRTier) -> OCRTierConfiguration {
    switch tier {
    case .minimal:
      return OCRTierConfiguration(
        tier: tier,
        intraOpNumThreads: minimalIntraOpNumThreads,
        detectionInputLongSide: minimalDetectionInputLongSide,
        recognitionBatchSize: minimalRecognitionBatchSize,
        runsOrientationClassifier: minimalRunsOrientationClassifier,
        queueDepth: minimalQueueDepth
      )
    case .balanced:
      return OCRTierConfiguration(
        tier: tier,
        intraOpNumThreads: balancedIntraOpNumThreads,
        detectionInputLongSide: balancedDetectionInputLongSide,
        recognitionBatchSize: balancedRecognitionBatchSize,
        runsOrientationClassifier: balancedRunsOrientationClassifier,
        queueDepth: balancedQueueDepth
      )
    case .performance:
      return OCRTierConfiguration(
        tier: tier,
        intraOpNumThreads: performanceIntraOpNumThreads,
        detectionInputLongSide: performanceDetectionInputLongSide,
        recognitionBatchSize: performanceRecognitionBatchSize,
        runsOrientationClassifier: performanceRunsOrientationClassifier,
        queueDepth: performanceQueueDepth
      )
    }
  }

  /// Computes the heaviest tier this machine can safely sustain right now.
  /// This is a **ceiling**, not the final answer — the final tier choice also
  /// depends on the user's `TextRecognitionQuality` preference (see
  /// `selectTier` for the full algorithm).
  ///
  /// Algorithm:
  /// 1. Compute `effectiveCores`: the minimum of physical cores and any cgroup
  ///    CPU quota. If a cgroup quota applies (e.g., "0.5 CPUs" in a container),
  ///    ONNX Runtime must never plan more threads than the quota permits, or
  ///    it oversubscribes and thrashes.
  /// 2. Return `.minimal` if available RAM is below `balancedRAMFloorMB` OR
  ///    effective cores below `balancedCoreFloor`.
  /// 3. Return `.balanced` if available RAM is below `performanceRAMFloorMB`
  ///    OR effective cores below `performanceCoreFloor` OR AVX-2 is missing.
  ///    (AVX-2 quantized models run significantly slower.)
  /// 4. Return `.performance` if all checks pass.
  /// 5. If `capacity.onBattery` is true, clamp the result down to at most
  ///    `.balanced` (save battery: trade raw throughput for power efficiency).
  ///
  /// - Parameter capacity: The machine's resource snapshot.
  /// - Returns: The maximum tier the machine can safely sustain.
  public static func capacityCeiling(capacity: MachineCapacity) -> OCRTier {
    // Compute effective cores: never exceed the cgroup quota.
    let cgroupCoreBudget = capacity.cgroupCPUQuota.map { max(1, Int($0)) } ?? capacity.physicalCores
    let effectiveCores = min(capacity.physicalCores, cgroupCoreBudget)

    // Check RAM and core minimums for each tier.
    if capacity.availableRAMMB < balancedRAMFloorMB || effectiveCores < balancedCoreFloor {
      return .minimal
    }

    if capacity.availableRAMMB < performanceRAMFloorMB || effectiveCores < performanceCoreFloor
      || !capacity.hasAVX2
    {
      return .balanced
    }

    var ceiling: OCRTier = .performance

    // On battery: clamp to `.balanced` to save power.
    if capacity.onBattery {
      ceiling = min(ceiling, .balanced)
    }

    return ceiling
  }

  /// Selects the final tier by combining the capacity ceiling with the user's
  /// `TextRecognitionQuality` preference.
  ///
  /// Algorithm:
  /// - If `override` is `.forced(tier)`, return that tier as-is (bypass all
  ///   logic).
  /// - If `quality` is `.accurate`, use the full capacity ceiling.
  /// - If `quality` is `.fast`, step one tier down from the ceiling (never
  ///   below `.minimal`). This trades some accuracy for speed, mirroring the
  ///   macOS `VisionTextRecognizer.swift` pattern.
  ///
  /// The quality choice is a user-facing knob that was tested on real
  /// screenshots; see `TextRecognitionQuality.swift` for details.
  ///
  /// - Parameters:
  ///   - capacity: The machine's resource snapshot.
  ///   - quality: The user's desired speed/accuracy tradeoff.
  ///   - override: Force a specific tier (for tests or advanced settings).
  /// - Returns: The selected tier.
  public static func selectTier(
    capacity: MachineCapacity,
    quality: TextRecognitionQuality,
    override: OCRTierOverride = .automatic
  ) -> OCRTier {
    // Explicit override: bypass all logic.
    if case .forced(let tier) = override {
      return tier
    }

    let ceiling = capacityCeiling(capacity: capacity)

    switch quality {
    case .accurate:
      return ceiling
    case .fast:
      // Step one tier down, but never below `.minimal`.
      if ceiling > .minimal {
        return ceiling < .performance ? .minimal : .balanced
      }
      return .minimal
    }
  }

  /// Convenience function: combines `selectTier` and `configuration` in one call.
  /// Returns the full `OCRTierConfiguration` for the selected tier.
  ///
  /// - Parameters:
  ///   - capacity: The machine's resource snapshot.
  ///   - quality: The user's desired speed/accuracy tradeoff.
  ///   - override: Force a specific tier (for tests or advanced settings).
  /// - Returns: The configuration for the selected tier.
  public static func select(
    capacity: MachineCapacity,
    quality: TextRecognitionQuality,
    override: OCRTierOverride = .automatic
  ) -> OCRTierConfiguration {
    configuration(for: selectTier(capacity: capacity, quality: quality, override: override))
  }
}
