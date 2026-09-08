import Foundation
import Testing

@testable import ClipnestCore
@testable import ClipnestLinuxOCR

@Suite("OCRTierSelector")
struct OCRTierSelectorTests {

  // MARK: - capacityCeiling tests

  @Test("should_return_minimal_for_low_RAM_box")
  func capacityCeilingLowRAM() {
    let capacity = MachineCapacity(
      physicalCores: 8,
      logicalCores: 16,
      availableRAMMB: 512,  // Below balancedRAMFloorMB (1024)
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: nil
    )
    let ceiling = OCRTierSelector.capacityCeiling(capacity: capacity)
    #expect(ceiling == .minimal)
  }

  @Test("should_return_minimal_for_low_core_count_box")
  func capacityCeilingLowCores() {
    let capacity = MachineCapacity(
      physicalCores: 1,
      logicalCores: 1,
      availableRAMMB: 4096,  // Plenty of RAM
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: nil
    )
    let ceiling = OCRTierSelector.capacityCeiling(capacity: capacity)
    #expect(ceiling == .minimal)
  }

  @Test("should_return_balanced_for_mid_range_box")
  func capacityCeilingBalancedBox() {
    let capacity = MachineCapacity(
      physicalCores: 4,
      logicalCores: 8,
      // Above balancedRAMFloorMB (1024), genuinely BELOW performanceRAMFloorMB
      // (2048) — the original 2048 here was a boundary-condition test bug:
      // 2048 is NOT below a 2048 floor, it MEETS it, so the ceiling was
      // (correctly) `.performance`, not `.balanced` as this test intended.
      // Found by this task's Docker verification run.
      availableRAMMB: 1536,
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: nil
    )
    let ceiling = OCRTierSelector.capacityCeiling(capacity: capacity)
    #expect(ceiling == .balanced)
  }

  @Test("should_return_performance_for_high_end_box")
  func capacityCeilingPerformanceBox() {
    let capacity = MachineCapacity(
      physicalCores: 8,
      logicalCores: 16,
      availableRAMMB: 4096,  // Above both RAM floors
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: nil
    )
    let ceiling = OCRTierSelector.capacityCeiling(capacity: capacity)
    #expect(ceiling == .performance)
  }

  @Test("should_respect_cgroup_CPU_quota_limit")
  func capacityCeilingCgroupLimit() {
    let capacity = MachineCapacity(
      physicalCores: 8,
      logicalCores: 16,
      availableRAMMB: 4096,
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: 1.5  // Only 1.5 CPUs allowed, so effectiveCores = 1
    )
    let ceiling = OCRTierSelector.capacityCeiling(capacity: capacity)
    #expect(ceiling == .minimal)  // effectiveCores (1) < balancedCoreFloor (2)
  }

  @Test("should_clamp_to_balanced_when_on_battery")
  func capacityCeilingOnBattery() {
    let capacity = MachineCapacity(
      physicalCores: 8,
      logicalCores: 16,
      availableRAMMB: 4096,
      hasAVX2: true,
      onBattery: true,  // On battery
      cgroupCPUQuota: nil
    )
    let ceiling = OCRTierSelector.capacityCeiling(capacity: capacity)
    #expect(ceiling == .balanced)  // Would be .performance, but battery clamps to .balanced
  }

  @Test("should_return_balanced_without_AVX2_despite_good_hardware")
  func capacityCeilingNoAVX2() {
    let capacity = MachineCapacity(
      physicalCores: 8,
      logicalCores: 16,
      availableRAMMB: 4096,
      hasAVX2: false,  // No AVX-2
      onBattery: false,
      cgroupCPUQuota: nil
    )
    let ceiling = OCRTierSelector.capacityCeiling(capacity: capacity)
    #expect(ceiling == .balanced)  // Capped at balanced due to missing AVX-2
  }

  // MARK: - selectTier tests

  @Test("should_use_full_ceiling_for_accurate_quality")
  func selectTierAccurateUsesFullCeiling() {
    let capacity = MachineCapacity(
      physicalCores: 8,
      logicalCores: 16,
      availableRAMMB: 4096,
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: nil
    )
    let tier = OCRTierSelector.selectTier(
      capacity: capacity,
      quality: .accurate,
      override: .automatic
    )
    #expect(tier == .performance)  // Ceiling is .performance, accurate uses it fully
  }

  @Test("should_step_down_one_tier_for_fast_quality")
  func selectTierFastStepsDown() {
    let capacity = MachineCapacity(
      physicalCores: 8,
      logicalCores: 16,
      availableRAMMB: 4096,
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: nil
    )
    let tier = OCRTierSelector.selectTier(
      capacity: capacity,
      quality: .fast,
      override: .automatic
    )
    #expect(tier == .balanced)  // Ceiling is .performance, fast steps down to .balanced
  }

  @Test("should_not_step_below_minimal_for_fast_quality")
  func selectTierFastStaysAtMinimal() {
    let capacity = MachineCapacity(
      physicalCores: 1,
      logicalCores: 1,
      availableRAMMB: 512,
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: nil
    )
    let tier = OCRTierSelector.selectTier(
      capacity: capacity,
      quality: .fast,
      override: .automatic
    )
    #expect(tier == .minimal)  // Ceiling is .minimal, fast stays at .minimal
  }

  @Test("should_step_from_balanced_down_to_minimal_for_fast")
  func selectTierFastFromBalancedToMinimal() {
    let capacity = MachineCapacity(
      physicalCores: 4,
      logicalCores: 8,
      // See `capacityCeiling_balancedBox`'s comment: must be strictly below
      // `performanceRAMFloorMB` (2048) for the ceiling to actually be
      // `.balanced`, not `.performance`.
      availableRAMMB: 1536,
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: nil
    )
    let tier = OCRTierSelector.selectTier(
      capacity: capacity,
      quality: .fast,
      override: .automatic
    )
    #expect(tier == .minimal)  // Ceiling is .balanced, fast steps down to .minimal
  }

  @Test("should_bypass_logic_with_forced_override")
  func selectTierForcedOverride() {
    let capacity = MachineCapacity(
      physicalCores: 1,
      logicalCores: 1,
      availableRAMMB: 256,
      hasAVX2: false,
      onBattery: true,
      cgroupCPUQuota: nil
    )
    let tier = OCRTierSelector.selectTier(
      capacity: capacity,
      quality: .fast,
      override: .forced(.performance)
    )
    #expect(tier == .performance)  // Override forces .performance regardless
  }

  // MARK: - select (convenience function) tests

  @Test("should_return_correct_configuration_for_selected_tier")
  func selectReturnsProperConfiguration() {
    let capacity = MachineCapacity(
      physicalCores: 8,
      logicalCores: 16,
      availableRAMMB: 4096,
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: nil
    )
    let config = OCRTierSelector.select(
      capacity: capacity,
      quality: .accurate,
      override: .automatic
    )
    #expect(config.tier == .performance)
    #expect(config.intraOpNumThreads == 4)
    #expect(config.detectionInputLongSide == 1280)
    #expect(config.recognitionBatchSize == 8)
    #expect(config.runsOrientationClassifier == true)
    #expect(config.queueDepth == 6)
  }

  // MARK: - Tier Comparable tests

  @Test("should_satisfy_minimal_less_than_balanced")
  func tierComparableMinimalLessThanBalanced() {
    #expect(OCRTier.minimal < .balanced)
  }

  @Test("should_satisfy_balanced_less_than_performance")
  func tierComparableBalancedLessThanPerformance() {
    #expect(OCRTier.balanced < .performance)
  }

  @Test("should_satisfy_minimal_less_than_performance")
  func tierComparableMinimalLessThanPerformance() {
    #expect(OCRTier.minimal < .performance)
  }

  @Test("should_satisfy_equal_tiers")
  func tierComparableEqualTiers() {
    #expect(OCRTier.balanced == .balanced)
    #expect(!(OCRTier.balanced < .balanced))
  }

  @Test("should_clamp_performance_to_balanced_on_battery")
  func tierComparableClampWithMin() {
    let tier = OCRTier.performance
    let clamped = min(tier, OCRTier.balanced)
    #expect(clamped == .balanced)
  }

  // MARK: - Edge cases

  @Test("should_handle_zero_RAM_available")
  func selectTierZeroRAM() {
    let capacity = MachineCapacity(
      physicalCores: 8,
      logicalCores: 16,
      availableRAMMB: 0,
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: nil
    )
    let tier = OCRTierSelector.selectTier(
      capacity: capacity,
      quality: .accurate,
      override: .automatic
    )
    #expect(tier == .minimal)  // 0 MB available → force minimal
  }

  @Test("should_handle_fractional_cgroup_quota_rounding")
  func selectTierFractionalCgroupQuota() {
    let capacity = MachineCapacity(
      physicalCores: 4,
      logicalCores: 8,
      availableRAMMB: 4096,
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: 0.8  // Less than 1 core, so Int($0) = 0, max(1, 0) = 1
    )
    let tier = OCRTierSelector.selectTier(
      capacity: capacity,
      quality: .accurate,
      override: .automatic
    )
    // effectiveCores = 1 (after max(1, Int(0.8))) < balancedCoreFloor (2)
    #expect(tier == .minimal)
  }

  @Test("should_handle_cgroup_quota_larger_than_physical_cores")
  func selectTierCgroupQuotaExceedsPhysicalCores() {
    let capacity = MachineCapacity(
      physicalCores: 2,
      logicalCores: 4,
      availableRAMMB: 4096,
      hasAVX2: true,
      onBattery: false,
      cgroupCPUQuota: 8.0  // Quota allows 8 CPUs, but only 2 physical
    )
    let tier = OCRTierSelector.selectTier(
      capacity: capacity,
      quality: .accurate,
      override: .automatic
    )
    #expect(tier == .balanced)  // effectiveCores = min(2, 8) = 2; balanced floor, above RAM floor
  }
}
