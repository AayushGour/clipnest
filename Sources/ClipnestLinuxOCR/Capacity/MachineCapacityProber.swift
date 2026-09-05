import Foundation

#if canImport(Glibc)
  import Glibc
#endif

/// Pure parsing logic for `/proc` and `/sys` capacity sources. Deliberately
/// separated from `LiveMachineCapacityProber`'s real file I/O so this logic is
/// unit-testable with synthetic file contents (e.g., a 4GB box with 300MB
/// free, a systemd `CPUQuota=` limit, or a container's `cpu.max` limit)
/// without requiring a real Linux filesystem.
///
/// All parsing functions return `nil` (or safe defaults) on malformed input —
/// callers must have fallbacks and never crash on a missing or corrupted
/// `/proc` or `/sys` file. This is especially important on unusual distros,
/// containers, or edge-case kernel configurations.
public enum MachineCapacityParsing {
  /// Parses `/proc/meminfo` for the `MemAvailable:` line and converts from
  /// kilobytes to whole megabytes (floored). Returns `nil` if the line is
  /// missing or malformed — callers must have a safe fallback (e.g.,
  /// availableRAMMB = 0).
  ///
  /// - Parameter procMeminfoContents: Raw contents of `/proc/meminfo` as a
  ///   single string.
  /// - Returns: Available RAM in MB (floored from kB), or `nil` if
  ///   `MemAvailable:` cannot be parsed.
  public static func parseAvailableRAMMB(procMeminfoContents: String) -> Int? {
    let lines = procMeminfoContents.split(separator: "\n", omittingEmptySubsequences: true)
    for line in lines {
      if line.starts(with: "MemAvailable:") {
        let components = line.split(separator: " ", omittingEmptySubsequences: true)
        if components.count >= 2, let kbValue = Int(components[1]) {
          return kbValue / 1024  // Convert kB to MB (floored)
        }
      }
    }
    return nil
  }

  /// Parses cgroup v2 `cpu.max` contents: two space-separated tokens,
  /// `<quota> <period>` in microseconds, or `max <period>` for unlimited.
  /// Returns quota/period as a Double (e.g., "100000 100000" -> 1.0,
  /// "50000 100000" -> 0.5). Returns `nil` for `"max ..."` (unlimited quota)
  /// or malformed input. **Note:** cgroup v1 (`cpu.cfs_quota_us` /
  /// `cpu.cfs_period_us` files) is explicitly out of scope for this
  /// implementation.
  ///
  /// - Parameter cpuMaxContents: Raw contents of `/sys/fs/cgroup/cpu.max` as
  ///   a single string.
  /// - Returns: Effective CPU quota as a ratio (e.g., 0.5 for half a CPU), or
  ///   `nil` if unlimited or malformed.
  public static func parseCgroupCPUQuota(cpuMaxContents: String) -> Double? {
    let trimmed = cpuMaxContents.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = trimmed.split(separator: " ", omittingEmptySubsequences: true)

    guard components.count >= 2 else { return nil }

    // If the quota is "max", it means unlimited — return nil.
    if components[0] == "max" {
      return nil
    }

    // Parse both quota and period as integers.
    guard
      let quotaMicroseconds = Int(components[0]),
      let periodMicroseconds = Int(components[1])
    else {
      return nil
    }

    // Avoid division by zero.
    guard periodMicroseconds > 0 else { return nil }

    // Return the ratio as a Double.
    return Double(quotaMicroseconds) / Double(periodMicroseconds)
  }

  /// Parses `/proc/cpuinfo` for a `flags` (or `Features` on some non-x86
  /// architectures) line and checks whether the `avx2` token is present.
  /// Checks every flags line found (since `/proc/cpuinfo` repeats one block
  /// per logical CPU) — different cores are never asymmetric on AVX-2 in
  /// practice, but checking every line is the honest choice and has no cost.
  /// Returns false if no flags/Features line is found (e.g., non-x86
  /// architectures like ARM have no AVX-2 concept).
  ///
  /// - Parameter procCpuinfoContents: Raw contents of `/proc/cpuinfo` as a
  ///   single string.
  /// - Returns: `true` if AVX-2 is found in any flags line, `false`
  ///   otherwise.
  public static func parseHasAVX2(procCpuinfoContents: String) -> Bool {
    let lines = procCpuinfoContents.split(separator: "\n", omittingEmptySubsequences: true)
    for line in lines {
      // Look for either "flags" (x86) or "Features" (some non-x86).
      if line.starts(with: "flags") || line.starts(with: "Features") {
        if line.lowercased().contains("avx2") {
          return true
        }
      }
    }
    return false
  }

  /// Parses the distinct physical core count from a list of core ID strings.
  /// `coreIDValues` contains the raw string contents of every
  /// `/sys/devices/system/cpu/cpu*/topology/core_id` file found (e.g.,
  /// `["0", "1", "0", "1"]` on a 2-physical/4-logical hyperthreaded box).
  /// Returns the count of DISTINCT values.
  ///
  /// **Known simplification (intentional, per the plan's spec):** A true
  /// multi-socket dedup would also need `physical_package_id` to distinguish
  /// core 0 on socket 0 from core 0 on socket 1. Out of scope here — this
  /// implementation assumes single-socket or treats all cores uniformly.
  ///
  /// Returns 1 if the input is empty (never report 0 cores).
  ///
  /// - Parameter coreIDValues: Raw `core_id` strings, one per logical CPU.
  /// - Returns: Count of distinct core IDs (at least 1).
  public static func parsePhysicalCoreCount(coreIDValues: [String]) -> Int {
    guard !coreIDValues.isEmpty else { return 1 }
    let uniqueIDs = Set(coreIDValues)
    return max(1, uniqueIDs.count)
  }

  /// Parses one `/sys/class/power_supply/AC*/online` file for battery status.
  /// `acOnlineContents` is the raw file contents (e.g., `"0"` or `"1"`,
  /// possibly with trailing whitespace/newline).
  /// Returns `true` (on battery) only when the trimmed content is exactly
  /// `"0"`. Any other value (including malformed input) is treated as AC
  /// power available (not on battery).
  ///
  /// - Parameter acOnlineContents: Raw contents of an AC online file.
  /// - Returns: `true` if the trimmed value is `"0"` (on battery), `false`
  ///   otherwise.
  public static func parseOnBattery(acOnlineContents: String) -> Bool {
    let trimmed = acOnlineContents.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == "0"
  }
}

/// Protocol for live machine capacity probing (Sendable for use in async
/// contexts).
public protocol MachineCapacityProbing: Sendable {
  func probe() -> MachineCapacity
}

/// Probes the actual capabilities of the current machine, live, via `/proc`,
/// `/sys`, and `sysconf`. Production implementation of `MachineCapacityProbing`.
///
/// All file reads are wrapped in `try?` — missing or unreadable files on an
/// unusual distro, container, or misconfigured system must never crash the
/// OCR module. Instead, each field falls back to a safe default (e.g.,
/// availableRAMMB = 0 → tier selector picks `.minimal`).
public struct LiveMachineCapacityProber: MachineCapacityProbing {
  public init() {}

  public func probe() -> MachineCapacity {
    let physicalCores = readPhysicalCores()
    let logicalCores = readLogicalCores()
    let availableRAMMB = readAvailableRAMMB()
    let hasAVX2 = readHasAVX2()
    let onBattery = readOnBattery()
    let cgroupCPUQuota = readCgroupCPUQuota()

    return MachineCapacity(
      physicalCores: physicalCores,
      logicalCores: logicalCores,
      availableRAMMB: availableRAMMB,
      hasAVX2: hasAVX2,
      onBattery: onBattery,
      cgroupCPUQuota: cgroupCPUQuota
    )
  }

  // MARK: - Private file readers

  private func readPhysicalCores() -> Int {
    let cpuDir = "/sys/devices/system/cpu"
    guard let fileManager = FileManager.default as FileManager? else {
      return 1
    }

    do {
      let cpuDirContents = try fileManager.contentsOfDirectory(atPath: cpuDir)
      var coreIDs: [String] = []

      for cpuEntry in cpuDirContents {
        if cpuEntry.starts(with: "cpu"), Int(cpuEntry.dropFirst(3)) != nil {
          let coreIDPath = cpuDir + "/" + cpuEntry + "/topology/core_id"
          if let coreIDContent = try? String(
            contentsOfFile: coreIDPath, encoding: .utf8)
          {
            let trimmed = coreIDContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
              coreIDs.append(trimmed)
            }
          }
        }
      }

      if !coreIDs.isEmpty {
        return MachineCapacityParsing.parsePhysicalCoreCount(coreIDValues: coreIDs)
      }
    } catch {
      // Fall through to default
    }

    return 1
  }

  private func readLogicalCores() -> Int {
    #if canImport(Glibc)
      let nprocessors = sysconf(Int32(_SC_NPROCESSORS_ONLN))
      return nprocessors > 0 ? Int(nprocessors) : 1
    #else
      return 1
    #endif
  }

  private func readAvailableRAMMB() -> Int {
    let meminfoPath = "/proc/meminfo"
    do {
      let contents = try String(contentsOfFile: meminfoPath, encoding: .utf8)
      if let mb = MachineCapacityParsing.parseAvailableRAMMB(procMeminfoContents: contents) {
        return mb
      }
    } catch {
      // Fall through to default
    }
    return 0
  }

  private func readHasAVX2() -> Bool {
    let cpuinfoPath = "/proc/cpuinfo"
    do {
      let contents = try String(contentsOfFile: cpuinfoPath, encoding: .utf8)
      return MachineCapacityParsing.parseHasAVX2(procCpuinfoContents: contents)
    } catch {
      // Fall through to default
    }
    return false
  }

  private func readOnBattery() -> Bool {
    let acDir = "/sys/class/power_supply"
    guard let fileManager = FileManager.default as FileManager? else {
      return false
    }

    do {
      let acDirContents = try fileManager.contentsOfDirectory(atPath: acDir)
      for acEntry in acDirContents {
        if acEntry.starts(with: "AC") {
          let onlinePath = acDir + "/" + acEntry + "/online"
          if let onlineContent = try? String(
            contentsOfFile: onlinePath, encoding: .utf8)
          {
            if MachineCapacityParsing.parseOnBattery(acOnlineContents: onlineContent) {
              return true
            }
          }
        }
      }
    } catch {
      // Fall through to default
    }

    return false
  }

  private func readCgroupCPUQuota() -> Double? {
    let cpuMaxPath = "/sys/fs/cgroup/cpu.max"
    do {
      let contents = try String(contentsOfFile: cpuMaxPath, encoding: .utf8)
      return MachineCapacityParsing.parseCgroupCPUQuota(cpuMaxContents: contents)
    } catch {
      // Fall through to nil (no cgroup limit)
    }
    return nil
  }
}
