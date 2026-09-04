// ProcessMetrics.swift
//
// Resident-set-size sampling via `task_info(MACH_TASK_BASIC_INFO)` — the
// standard low-overhead way to read this process's own RSS on Darwin
// without shelling out to `ps` on every sample (which would itself perturb
// the main-actor heartbeat measurement by spawning processes).
import Darwin
import Foundation

enum ProcessMetrics {
  static func residentSetSizeBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPointer, &count)
      }
    }
    guard kerr == KERN_SUCCESS else { return 0 }
    return info.resident_size
  }

  static func residentSetSizeMB() -> Double {
    Double(residentSetSizeBytes()) / 1_048_576
  }
}
