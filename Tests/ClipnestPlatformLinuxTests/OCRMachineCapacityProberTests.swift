import Foundation
import Testing

@testable import ClipnestLinuxOCR

@Suite("OCRMachineCapacityProber")
struct OCRMachineCapacityProberTests {

  // MARK: - parseAvailableRAMMB tests

  @Test("should_parse_MemAvailable_correctly_and_convert_KB_to_MB_floored")
  func parseAvailableRAMMB_convertsKBtoMBFloored() {
    let meminfoContent = """
      MemTotal:        8167852 kB
      MemFree:         307200 kB
      MemAvailable:    307200 kB
      Buffers:         49152 kB
      """
    let result = MachineCapacityParsing.parseAvailableRAMMB(procMeminfoContents: meminfoContent)
    #expect(result == 300)  // 307200 / 1024 = 300.0 (floored)
  }

  @Test("should_return_nil_when_MemAvailable_line_is_missing")
  func parseAvailableRAMMB_returnsNilWhenMissing() {
    let meminfoContent = """
      MemTotal:        8167852 kB
      MemFree:         307200 kB
      Buffers:         49152 kB
      """
    let result = MachineCapacityParsing.parseAvailableRAMMB(procMeminfoContents: meminfoContent)
    #expect(result == nil)
  }

  @Test("should_handle_MemAvailable_with_various_whitespace")
  func parseAvailableRAMMB_handlesWhitespace() {
    let meminfoContent = "MemAvailable:   1048576 kB"
    let result = MachineCapacityParsing.parseAvailableRAMMB(procMeminfoContents: meminfoContent)
    #expect(result == 1024)  // 1048576 / 1024 = 1024
  }

  @Test("should_return_nil_on_malformed_MemAvailable_value")
  func parseAvailableRAMMB_returnsNilOnMalformedValue() {
    let meminfoContent = "MemAvailable:   not_a_number kB"
    let result = MachineCapacityParsing.parseAvailableRAMMB(procMeminfoContents: meminfoContent)
    #expect(result == nil)
  }

  // MARK: - parseCgroupCPUQuota tests

  @Test("should_parse_cpu_max_quota_equal_to_period_as_1_point_0")
  func parseCgroupCPUQuota_quota_equals_period() {
    let result = MachineCapacityParsing.parseCgroupCPUQuota(cpuMaxContents: "100000 100000")
    #expect(result == 1.0)
  }

  @Test("should_parse_cpu_max_half_quota")
  func parseCgroupCPUQuota_half_quota() {
    let result = MachineCapacityParsing.parseCgroupCPUQuota(cpuMaxContents: "50000 100000")
    #expect(result == 0.5)
  }

  @Test("should_parse_cpu_max_with_extra_whitespace")
  func parseCgroupCPUQuota_extraWhitespace() {
    let result = MachineCapacityParsing.parseCgroupCPUQuota(cpuMaxContents: "  75000  150000  ")
    #expect(result == 0.5)
  }

  @Test("should_return_nil_for_unlimited_max_quota")
  func parseCgroupCPUQuota_unlimited() {
    let result = MachineCapacityParsing.parseCgroupCPUQuota(cpuMaxContents: "max 100000")
    #expect(result == nil)
  }

  @Test("should_return_nil_for_malformed_cpu_max")
  func parseCgroupCPUQuota_malformed() {
    let result = MachineCapacityParsing.parseCgroupCPUQuota(cpuMaxContents: "not a number 100000")
    #expect(result == nil)
  }

  @Test("should_return_nil_for_single_token_cpu_max")
  func parseCgroupCPUQuota_singleToken() {
    let result = MachineCapacityParsing.parseCgroupCPUQuota(cpuMaxContents: "100000")
    #expect(result == nil)
  }

  @Test("should_return_nil_for_zero_period")
  func parseCgroupCPUQuota_zeroPeriod() {
    let result = MachineCapacityParsing.parseCgroupCPUQuota(cpuMaxContents: "100000 0")
    #expect(result == nil)
  }

  // MARK: - parseHasAVX2 tests

  @Test("should_detect_AVX2_in_flags_line")
  func parseHasAVX2_detects_avx2() {
    let cpuinfoContent = """
      processor\t: 0
      vendor_id\t: GenuineIntel
      flags\t\t: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx rdtscp lm constant_tsc art arch_perfmon pebs bts rep_good nopl xtopology nonstop_tsc cpuid aperfmperf pni pclmulqdq dtes64 monitor ds_cpl vmx est tm2 ssse3 cx16 xtpr pdcm pcid sse4_1 sse4_2 x2apic popcnt tsc_deadline_timer aes xsave avx f16c rdrand lahf_lm abm cpuid_fault invpcid_single pti ssbd ibrs ibpb stibp tpr_shadow vnmi flexpriority ept vpid fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid rdseed adx smap intel_pt xsaveopt xsavec xgetbv1 xsaves dtherm ida arat pln pts hwp hwp_notify hwp_act_perf dba
      """
    let result = MachineCapacityParsing.parseHasAVX2(procCpuinfoContents: cpuinfoContent)
    #expect(result == true)
  }

  @Test("should_return_false_when_AVX2_is_not_present")
  func parseHasAVX2_not_present() {
    let cpuinfoContent = """
      processor\t: 0
      vendor_id\t: GenuineIntel
      flags\t\t: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx rdtscp lm constant_tsc
      """
    let result = MachineCapacityParsing.parseHasAVX2(procCpuinfoContents: cpuinfoContent)
    #expect(result == false)
  }

  @Test("should_return_false_when_no_flags_line_exists")
  func parseHasAVX2_noFlagsLine() {
    let cpuinfoContent = """
      processor\t: 0
      vendor_id\t: GenuineIntel
      model\t\t: 142
      """
    let result = MachineCapacityParsing.parseHasAVX2(procCpuinfoContents: cpuinfoContent)
    #expect(result == false)
  }

  @Test("should_detect_AVX2_in_Features_line_non_x86")
  func parseHasAVX2_features_line() {
    let cpuinfoContent = """
      processor\t: 0
      Features\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp ssbs
      """
    let result = MachineCapacityParsing.parseHasAVX2(procCpuinfoContents: cpuinfoContent)
    #expect(result == false)  // Features line, but no AVX2 (this is ARM)
  }

  // MARK: - parsePhysicalCoreCount tests

  @Test("should_count_distinct_core_IDs_correctly")
  func parsePhysicalCoreCount_distinctCores() {
    let coreIDs = ["0", "1", "0", "1"]
    let result = MachineCapacityParsing.parsePhysicalCoreCount(coreIDValues: coreIDs)
    #expect(result == 2)  // Two distinct core IDs: 0 and 1
  }

  @Test("should_handle_single_core_ID")
  func parsePhysicalCoreCount_singleCore() {
    let coreIDs = ["0", "0", "0", "0"]
    let result = MachineCapacityParsing.parsePhysicalCoreCount(coreIDValues: coreIDs)
    #expect(result == 1)
  }

  @Test("should_return_1_for_empty_input")
  func parsePhysicalCoreCount_emptyInput() {
    let coreIDs: [String] = []
    let result = MachineCapacityParsing.parsePhysicalCoreCount(coreIDValues: coreIDs)
    #expect(result == 1)  // Never return 0
  }

  @Test("should_handle_many_cores_correctly")
  func parsePhysicalCoreCount_manyCores() {
    let coreIDs = ["0", "1", "2", "3", "0", "1", "2", "3"]
    let result = MachineCapacityParsing.parsePhysicalCoreCount(coreIDValues: coreIDs)
    #expect(result == 4)
  }

  // MARK: - parseOnBattery tests

  @Test("should_return_true_when_AC_online_is_0")
  func parseOnBattery_onBattery() {
    let result = MachineCapacityParsing.parseOnBattery(acOnlineContents: "0")
    #expect(result == true)
  }

  @Test("should_return_false_when_AC_online_is_1")
  func parseOnBattery_notOnBattery() {
    let result = MachineCapacityParsing.parseOnBattery(acOnlineContents: "1")
    #expect(result == false)
  }

  @Test("should_handle_trailing_newline_in_AC_online")
  func parseOnBattery_trailingNewline() {
    let result = MachineCapacityParsing.parseOnBattery(acOnlineContents: "0\n")
    #expect(result == true)
  }

  @Test("should_handle_whitespace_around_AC_online_value")
  func parseOnBattery_whitespace() {
    let result = MachineCapacityParsing.parseOnBattery(acOnlineContents: "  1  \n")
    #expect(result == false)
  }

  @Test("should_return_false_for_malformed_AC_online")
  func parseOnBattery_malformed() {
    let result = MachineCapacityParsing.parseOnBattery(acOnlineContents: "unknown")
    #expect(result == false)
  }
}
