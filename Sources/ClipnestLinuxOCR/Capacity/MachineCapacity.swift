/// MachineCapacity.swift
///
/// Encapsulates the machine's CPU and memory resources relevant to ONNX Runtime
/// PP-OCRv5 inference, read from Linux-specific sources (`/proc`, `/sys`).
/// Each field is populated by `MachineCapacityProber`'s real file I/O or
/// `MachineCapacityParsing`'s pure parsing logic.
///
/// CRITICAL DECISION (logged in project-context.md): `availableRAMMB` MUST
/// come from `/proc/meminfo`'s `MemAvailable` line (memory actually available
/// to user processes *right now*), **never** `MemTotal` (the machine's total
/// physical RAM). A 4GB box with only 300MB actually free must not spin up
/// 4 ONNX Runtime threads — doing so causes thrashing and hangs. This struct
/// enforces that contract: `availableRAMMB` is directly tied to `MemAvailable`
/// in the prober's implementation.

public struct MachineCapacity: Sendable, Equatable {
  /// Number of *physical* CPU cores (not logical/hyperthreaded). Parsed from
  /// the distinct `core_id` values in `/sys/devices/system/cpu/cpu*/topology/`.
  /// Defaults to `logicalCores` if core_id files are unreadable (e.g. on
  /// non-x86 architectures where the path doesn't exist).
  public let physicalCores: Int

  /// Number of *logical* CPU cores (CPUs visible to the OS, including
  /// hyperthreading). From `sysconf(_SC_NPROCESSORS_ONLN)`.
  public let logicalCores: Int

  /// Available RAM in whole megabytes, floored (e.g. 307200 kB from
  /// `/proc/meminfo` `MemAvailable:` becomes 300 MB, never 300.2). Read
  /// from `/proc/meminfo`'s `MemAvailable` line; **intentionally not
  /// `MemTotal`**. If `MemAvailable` is unreadable, defaults to 0 (forcing
  /// the tier selector to the safe `.minimal` tier). Never negative; always
  /// floored from the original kilobyte value.
  public let availableRAMMB: Int

  /// True if the CPU supports AVX-2 instruction extensions, parsed from
  /// `/proc/cpuinfo` `flags` (or `Features` on some non-x86 architectures).
  /// False if the flag line is missing or AVX-2 is not listed (e.g. older
  /// CPUs, ARM boxes). ONNX Runtime's quantized model implementations may
  /// run slower without AVX-2, so this is factored into tier selection.
  public let hasAVX2: Bool

  /// True if the machine is currently on battery power. Parsed from
  /// `/sys/class/power_supply/AC*/online` files (if AC adapter reports "0",
  /// the box is on battery). If no AC*/online files exist (e.g. a desktop
  /// with no power-supply monitoring), defaults to false (assume AC).
  public let onBattery: Bool

  /// If the machine is inside a cgroup v2 with CPU quotas, the ratio of
  /// quota to period (e.g., "50000 100000" -> 0.5, meaning 0.5 whole CPUs
  /// allowed). Parsed from `/sys/fs/cgroup/cpu.max` (cgroup v1 is out of
  /// scope for this implementation).
  /// Nil means either no cgroup limit applies (`cpu.max` contains "max ..."
  /// for unlimited) or the file is unreadable (treat as unlimited). The tier
  /// selector uses this to cap thread planning: never let ONNX Runtime
  /// allocate more threads than the cgroup actually permits, or it
  /// oversubscribes and thrashes.
  public let cgroupCPUQuota: Double?

  public init(
    physicalCores: Int,
    logicalCores: Int,
    availableRAMMB: Int,
    hasAVX2: Bool,
    onBattery: Bool,
    cgroupCPUQuota: Double?
  ) {
    self.physicalCores = physicalCores
    self.logicalCores = logicalCores
    self.availableRAMMB = availableRAMMB
    self.hasAVX2 = hasAVX2
    self.onBattery = onBattery
    self.cgroupCPUQuota = cgroupCPUQuota
  }
}
