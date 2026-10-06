import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("IBusAddressResolution")
struct IBusAddressResolutionTests {
  /// In-memory fake filesystem: maps a path to its contents. A missing key
  /// models "file does not exist" (`readFile` returns `nil`), matching
  /// `AccessibilityBusResolver`/`SessionType`'s injected-fake pattern —
  /// zero real filesystem access from any test in this suite.
  private func readFile(from files: [String: String]) -> (String) -> String? {
    { path in files[path] }
  }

  private let baseEnvironment: [String: String] = [
    "HOME": "/home/alice",
    "DISPLAY": ":0",
  ]

  // MARK: - IBUS_ADDRESS precedence

  @Test("IBUS_ADDRESS takes precedence over any socket file")
  func environmentVariableWins() {
    var environment = baseEnvironment
    environment["IBUS_ADDRESS"] = "unix:abstract=/tmp/from-env,guid=1"
    let files = [
      "/home/alice/.config/ibus/bus/deadbeef-unix-0":
        "IBUS_ADDRESS=unix:abstract=/tmp/from-file,guid=2\n"
    ]
    let result = IBusAddressResolution.resolve(
      environment: environment, readFile: readFile(from: files))
    #expect(result == "unix:abstract=/tmp/from-env,guid=1")
  }

  @Test("an empty IBUS_ADDRESS is treated as unset, falling through to the file")
  func emptyEnvironmentVariableFallsThrough() {
    var environment = baseEnvironment
    environment["IBUS_ADDRESS"] = ""
    let fileName = IBusAddressResolution.socketFileName(
      environment: environment, readFile: readFile(from: [:]))
    let files = [
      "/home/alice/.config/ibus/bus/\(fileName)":
        "IBUS_ADDRESS=unix:abstract=/tmp/from-file,guid=2\n"
    ]
    let result = IBusAddressResolution.resolve(
      environment: environment, readFile: readFile(from: files))
    #expect(result == "unix:abstract=/tmp/from-file,guid=2")
  }

  // MARK: - File fallback

  @Test("a missing file at both candidate locations degrades to nil")
  func missingFileDegradesToNil() {
    let result = IBusAddressResolution.resolve(
      environment: baseEnvironment, readFile: readFile(from: [:]))
    #expect(result == nil)
  }

  @Test("reads IBUS_ADDRESS= out of the config-dir candidate file")
  func readsAddressFromConfigDirFile() {
    let fileName = IBusAddressResolution.socketFileName(
      environment: baseEnvironment, readFile: readFile(from: [:]))
    let files = [
      "/home/alice/.config/ibus/bus/\(fileName)":
        "# This file is created by ibus-daemon, please do not modify it.\n"
        + "IBUS_ADDRESS=unix:abstract=/tmp/ibus-real,guid=abc\n"
        + "IBUS_DAEMON_PID=4242\n"
    ]
    let result = IBusAddressResolution.resolve(
      environment: baseEnvironment, readFile: readFile(from: files))
    #expect(result == "unix:abstract=/tmp/ibus-real,guid=abc")
  }

  @Test("both candidate paths are attempted, in config-dir-first order")
  func triesBothCandidatePaths() {
    var environment = baseEnvironment
    environment["XDG_RUNTIME_DIR"] = "/run/user/1000"
    let candidates = IBusAddressResolution.candidateSocketPaths(
      environment: environment, readFile: readFile(from: [:]))
    #expect(candidates.count == 2)
    #expect(candidates[0].hasPrefix("/home/alice/.config/ibus/bus/"))
    #expect(candidates[1].hasPrefix("/run/user/1000/ibus/bus/"))
  }

  @Test("falls through to the XDG_RUNTIME_DIR candidate when the config-dir file is absent")
  func fallsThroughToRuntimeDirCandidate() {
    var environment = baseEnvironment
    environment["XDG_RUNTIME_DIR"] = "/run/user/1000"
    let fileName = IBusAddressResolution.socketFileName(
      environment: environment, readFile: readFile(from: [:]))
    let files = [
      "/run/user/1000/ibus/bus/\(fileName)":
        "IBUS_ADDRESS=unix:abstract=/tmp/from-runtime-dir,guid=9\n"
    ]
    let result = IBusAddressResolution.resolve(
      environment: environment, readFile: readFile(from: files))
    #expect(result == "unix:abstract=/tmp/from-runtime-dir,guid=9")
  }

  @Test("honors XDG_CONFIG_HOME over the ~/.config default")
  func honorsXdgConfigHome() {
    var environment = baseEnvironment
    environment["XDG_CONFIG_HOME"] = "/custom/config"
    let fileName = IBusAddressResolution.socketFileName(
      environment: environment, readFile: readFile(from: [:]))
    let files = [
      "/custom/config/ibus/bus/\(fileName)":
        "IBUS_ADDRESS=unix:abstract=/tmp/from-custom-config,guid=1\n"
    ]
    let result = IBusAddressResolution.resolve(
      environment: environment, readFile: readFile(from: files))
    #expect(result == "unix:abstract=/tmp/from-custom-config,guid=1")
  }

  // MARK: - Malformed/garbage content never crashes

  @Test("an empty file degrades to nil")
  func emptyFileDegradesToNil() {
    #expect(IBusAddressResolution.parseAddress(fromSocketFileContents: "") == nil)
  }

  @Test("a file with no IBUS_ADDRESS= line degrades to nil")
  func garbageFileDegradesToNil() {
    let garbage = "this is not a key=value file at all\n\u{0}\u{1}binary\u{2}garbage\n===\n"
    #expect(IBusAddressResolution.parseAddress(fromSocketFileContents: garbage) == nil)
  }

  @Test("a comment-only file degrades to nil")
  func commentOnlyFileDegradesToNil() {
    let contents = "# just a comment\n# IBUS_ADDRESS=this-is-inside-a-comment\n"
    #expect(IBusAddressResolution.parseAddress(fromSocketFileContents: contents) == nil)
  }

  @Test("a key present but with an empty value degrades to nil")
  func emptyValueDegradesToNil() {
    #expect(IBusAddressResolution.parseAddress(fromSocketFileContents: "IBUS_ADDRESS=\n") == nil)
  }

  @Test("the last IBUS_ADDRESS= line wins when the file has more than one")
  func lastAddressLineWins() {
    let contents = "IBUS_ADDRESS=first\nIBUS_ADDRESS=second\n"
    #expect(IBusAddressResolution.parseAddress(fromSocketFileContents: contents) == "second")
  }

  @Test("resolve() never crashes on a malformed file at either candidate")
  func resolveNeverCrashesOnGarbage() {
    var environment = baseEnvironment
    environment["XDG_RUNTIME_DIR"] = "/run/user/1000"
    let fileName = IBusAddressResolution.socketFileName(
      environment: environment, readFile: readFile(from: [:]))
    let files = [
      "/home/alice/.config/ibus/bus/\(fileName)": "\u{0}\u{1}\u{2} not even text-shaped",
      "/run/user/1000/ibus/bus/\(fileName)": "",
    ]
    let result = IBusAddressResolution.resolve(
      environment: environment, readFile: readFile(from: files))
    #expect(result == nil)
  }

  // MARK: - Socket file name construction (machine-id / hostname / display)

  @Test("machine id is read from /var/lib/dbus/machine-id first")
  func machineIdPrefersVarLibDbus() {
    let files = [
      "/var/lib/dbus/machine-id": "abc123\n",
      "/etc/machine-id": "should-not-be-used\n",
    ]
    #expect(IBusAddressResolution.machineId(readFile: readFile(from: files)) == "abc123")
  }

  @Test("machine id falls back to /etc/machine-id when the first path is missing")
  func machineIdFallsBackToEtc() {
    let files = ["/etc/machine-id": "fallback-id\n"]
    #expect(IBusAddressResolution.machineId(readFile: readFile(from: files)) == "fallback-id")
  }

  @Test("machine id falls back to a literal placeholder when neither file exists")
  func machineIdFallsBackToLiteralWhenBothMissing() {
    #expect(IBusAddressResolution.machineId(readFile: readFile(from: [:])) == "machine-id")
  }

  @Test("DISPLAY=:0 (bare local display) yields hostname unix, display 0")
  func displayBareLocal() {
    let result = IBusAddressResolution.hostnameAndDisplayNumber(environment: ["DISPLAY": ":0"])
    #expect(result.hostname == "unix")
    #expect(result.displayNumber == "0")
  }

  @Test("DISPLAY=host:1.0 drops the screen number and keeps the host")
  func displayWithHostAndScreen() {
    let result = IBusAddressResolution.hostnameAndDisplayNumber(
      environment: ["DISPLAY": "host:1.0"])
    #expect(result.hostname == "host")
    #expect(result.displayNumber == "1")
  }

  @Test("WAYLAND_DISPLAY takes precedence over DISPLAY and uses its full value")
  func waylandDisplayTakesPrecedence() {
    let result = IBusAddressResolution.hostnameAndDisplayNumber(
      environment: ["WAYLAND_DISPLAY": "wayland-0", "DISPLAY": "host:1.0"])
    #expect(result.hostname == "unix")
    #expect(result.displayNumber == "wayland-0")
  }

  @Test("neither WAYLAND_DISPLAY nor DISPLAY set falls back to unix/0")
  func noDisplaySignalFallsBack() {
    let result = IBusAddressResolution.hostnameAndDisplayNumber(environment: [:])
    #expect(result.hostname == "unix")
    #expect(result.displayNumber == "0")
  }

  // MARK: - resolveWithDaemonPID / parseDaemonPID (T-IBUS-PIDLIVE)

  @Test("resolveWithDaemonPID pairs the address with the SAME file's IBUS_DAEMON_PID= line")
  func resolveWithDaemonPIDPairsPID() {
    let fileName = IBusAddressResolution.socketFileName(
      environment: baseEnvironment, readFile: readFile(from: [:]))
    let files = [
      "/home/alice/.config/ibus/bus/\(fileName)":
        "# This file is created by ibus-daemon, please do not modify it.\n"
        + "IBUS_ADDRESS=unix:abstract=/tmp/ibus-real,guid=abc\n"
        + "IBUS_DAEMON_PID=4242\n"
    ]
    let result = IBusAddressResolution.resolveWithDaemonPID(
      environment: baseEnvironment, readFile: readFile(from: files))
    #expect(result?.address == "unix:abstract=/tmp/ibus-real,guid=abc")
    #expect(result?.daemonPID == 4242)
  }

  @Test(
    "resolveWithDaemonPID via IBUS_ADDRESS env var reports a nil PID — upstream never consults one for that path"
  )
  func resolveWithDaemonPIDEnvVarHasNoPID() {
    var environment = baseEnvironment
    environment["IBUS_ADDRESS"] = "unix:abstract=/tmp/from-env,guid=1"
    let result = IBusAddressResolution.resolveWithDaemonPID(
      environment: environment, readFile: readFile(from: [:]))
    #expect(result?.address == "unix:abstract=/tmp/from-env,guid=1")
    #expect(result?.daemonPID == nil)
  }

  @Test("resolveWithDaemonPID reports a nil PID when the socket file has no IBUS_DAEMON_PID= line")
  func resolveWithDaemonPIDMissingPIDLineIsNil() {
    let fileName = IBusAddressResolution.socketFileName(
      environment: baseEnvironment, readFile: readFile(from: [:]))
    let files = [
      "/home/alice/.config/ibus/bus/\(fileName)":
        "IBUS_ADDRESS=unix:abstract=/tmp/ibus-real,guid=abc\n"
    ]
    let result = IBusAddressResolution.resolveWithDaemonPID(
      environment: baseEnvironment, readFile: readFile(from: files))
    #expect(result?.address == "unix:abstract=/tmp/ibus-real,guid=abc")
    #expect(result?.daemonPID == nil)
  }

  @Test(
    "resolve(environment:readFile:) is unaffected by adding daemon-PID awareness — same address, same precedence"
  )
  func resolveStillDropsPIDAndMatchesOldBehavior() {
    let fileName = IBusAddressResolution.socketFileName(
      environment: baseEnvironment, readFile: readFile(from: [:]))
    let files = [
      "/home/alice/.config/ibus/bus/\(fileName)":
        "IBUS_ADDRESS=unix:abstract=/tmp/ibus-real,guid=abc\nIBUS_DAEMON_PID=4242\n"
    ]
    let result = IBusAddressResolution.resolve(
      environment: baseEnvironment, readFile: readFile(from: files))
    #expect(result == "unix:abstract=/tmp/ibus-real,guid=abc")
  }

  @Test("parseDaemonPID: the last IBUS_DAEMON_PID= line wins when the file has more than one")
  func parseDaemonPIDLastLineWins() {
    let contents = "IBUS_DAEMON_PID=111\nIBUS_DAEMON_PID=222\n"
    #expect(IBusAddressResolution.parseDaemonPID(fromSocketFileContents: contents) == 222)
  }

  @Test("parseDaemonPID: a comment-only or missing-key file degrades to nil")
  func parseDaemonPIDMissingDegradesToNil() {
    #expect(IBusAddressResolution.parseDaemonPID(fromSocketFileContents: "") == nil)
    #expect(
      IBusAddressResolution.parseDaemonPID(fromSocketFileContents: "IBUS_ADDRESS=foo\n") == nil)
    #expect(
      IBusAddressResolution.parseDaemonPID(
        fromSocketFileContents: "# IBUS_DAEMON_PID=999 (inside a comment)\n") == nil)
  }

  @Test("parseDaemonPID: a non-numeric value never crashes, degrades to nil")
  func parseDaemonPIDGarbageDegradesToNil() {
    #expect(
      IBusAddressResolution.parseDaemonPID(fromSocketFileContents: "IBUS_DAEMON_PID=not-a-pid\n")
        == nil)
  }
}
