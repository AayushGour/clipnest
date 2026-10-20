// LinuxAppUpdater.swift
//
// T-LXUPD (routed: "give Linux the same self-update capability macOS has"):
// the Linux analogue of `ClipnestApp/Sources/System/AppUpdater.swift`. Same
// "Local-only, always" constraint as `UpdateChecker`/`GrantInputHelperClient`
// (coding-standards.md: no `URLSession`/sockets anywhere in the codebase) —
// every network call here is `/usr/bin/curl` via `Process`, the exact same
// pattern `UpdateChecker.fetchLatestReleaseJSON()` already established (a
// permitted extension of this app's one deliberate network exception, not a
// new one), never `URLSession`/`FoundationNetworking`.
//
// Per the port plan (`AppUpdater` branches on provenance): a package
// installed from a PPA/apt repository is apt's to update — self-updating
// behind apt's back would fight the package manager the next time it runs
// `apt upgrade`. A raw `.deb` install (no repository serving it) has no such
// owner, so an in-app, checksum-verified download + `pkexec apt-get install`
// is genuinely useful there. `detectProvenance()` is how that distinction is
// made — see `AptPolicyParsing`'s doc comment for how it's verified.
//
// NEVER auto-installs: `detectProvenance()`/`performUpdate(...)` are only
// ever invoked by `SettingsWindow+General.swift` in response to an explicit
// user action (an explicit "Check for Updates" click surfaces availability;
// installing needs its own separate confirmation dialog before
// `performUpdate` is ever called) — matches `AppUpdater`'s own doc comment:
// "the user chooses when to update."
//
// Checksum verification is mandatory, not advisory: `performUpdate` refuses
// to install (`.noChecksumPublished`) if the release has no published
// `<deb>.sha256` asset, and refuses (`.checksumMismatch`) if the downloaded
// bytes don't hash to the published digest — a matching HTTP 200 or a
// plausible file size is never treated as verification. Hashing reuses
// `BlobStore.contentHash(of:)` (`ClipnestCore`) — the project's one existing
// SHA-256-hex helper (coding-standards.md's DRY rule) — rather than a second
// implementation.
//
// `UInputPermissionChecker`/`GrantInputHelperClient` (this module) both
// `import ClipnestGTK` purely to construct/consume result types
// (`UInputPermissionStatus`/`UInputGrantOutcome`) that live in the LOWER
// module, because `ClipnestGTK` cannot import `ClipnestLinuxAppKit` (the
// dependency edge runs the other way). This file follows the identical
// pattern: `LinuxUpdateProvenance`/`LinuxUpdateStep`/`LinuxUpdateOutcome`/
// `LinuxAppUpdaterError` live in `SettingsWindow+General.swift`
// (`ClipnestGTK`) — the tab that needs to switch on them — not here.
import ClipnestCore
import ClipnestGTK
import ClipnestViewModels
import Foundation

public enum LinuxAppUpdater {
  /// The Debian package name this whole file is about — `clipnest`, never
  /// `clipnest-ocr`/`clipnest-ocr-data` (see `debian/control`). One named
  /// constant (coding-standards.md's "no magic strings"), not repeated
  /// inline at each of this type's several call sites below.
  public static let packageName = "clipnest"

  // MARK: - Provenance detection (`apt-cache policy`)

  static let aptCacheExecutablePath = "/usr/bin/apt-cache"

  /// Pure — the exact argument list `detectProvenance()` spawns
  /// `apt-cache` with, factored out so it's unit-testable without spawning
  /// a process, mirroring `UpdateChecker.curlArguments(for:)`/
  /// `GrantInputHelperClient.pkexecArguments(helperPath:)`'s identical
  /// split.
  public static func aptCachePolicyArguments(packageName: String = packageName) -> [String] {
    ["policy", packageName]
  }

  /// Detects whether `packageName` is currently owned by an apt repository
  /// (a PPA or any other configured origin) or was installed from a raw
  /// `.deb` with no repository serving it — see `AptPolicyParsing`'s doc
  /// comment for the real, verified distinction this reads.
  ///
  /// Returns `.undetermined` (never `.standaloneDebInstall`) on ANY
  /// detection failure — a missing `apt-cache` binary, non-UTF8 output, or
  /// an unparseable format — deliberately fail-safe: offering an in-app
  /// install when this code simply couldn't tell would risk fighting a
  /// repository it failed to notice.
  public static func detectProvenance(packageName: String = packageName) async
    -> LinuxUpdateProvenance
  {
    guard
      let output = await runCapturingStdout(
        executablePath: aptCacheExecutablePath,
        arguments: aptCachePolicyArguments(packageName: packageName))
    else {
      return .undetermined(reason: "apt-cache policy could not be run")
    }
    guard let text = String(data: output, encoding: .utf8) else {
      return .undetermined(reason: "apt-cache policy produced non-UTF-8 output")
    }
    return AptPolicyParsing.provenance(fromPolicyOutput: text)
  }

  /// The command shown verbatim (selectable, for copy-paste) in
  /// `SettingsWindow+General.swift` when `detectProvenance()` reports
  /// `.packageManaged` — updates through apt, exactly like any other
  /// apt-managed package on the machine, rather than fighting it with an
  /// in-app install.
  public static func aptUpgradeCommand(packageName: String = packageName) -> String {
    "sudo apt update && sudo apt install --only-upgrade \(packageName)"
  }

  // MARK: - System facts (architecture + series) needed to pick the right asset

  static let dpkgExecutablePath = "/usr/bin/dpkg"

  /// The Debian architecture name (`amd64`/`arm64`/…) this machine reports
  /// — matches the architecture segment of the `.deb` asset names
  /// `release-linux.yml` publishes (`clipnest_<version>_<arch>-<series>.deb`).
  public static func currentArchitecture() async -> String? {
    guard
      let data = await runCapturingStdout(
        executablePath: dpkgExecutablePath, arguments: ["--print-architecture"])
    else { return nil }
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Pure — parses `VERSION_CODENAME=` out of an `/etc/os-release`-shaped
  /// file's contents (e.g. `"jammy"`, `"noble"`), handling both the quoted
  /// and unquoted forms the spec allows. Factored out from
  /// `currentSeries(osReleasePath:)` so it's unit-testable against a fixture
  /// string rather than the real `/etc/os-release`.
  public enum OSReleaseParsing {
    static let versionCodenameKey = "VERSION_CODENAME="

    public static func versionCodename(fromContents contents: String) -> String? {
      for line in contents.components(separatedBy: "\n") {
        guard line.hasPrefix(versionCodenameKey) else { continue }
        var value = String(line.dropFirst(versionCodenameKey.count))
          .trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
          value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
      }
      return nil
    }
  }

  public static let defaultOSReleasePath = "/etc/os-release"

  /// The Ubuntu series codename (`"jammy"`, `"noble"`, …) this machine is
  /// running — matches the series segment of the `.deb` asset names
  /// `release-linux.yml` publishes. A plain file read (no `Process` spawn
  /// needed — `/etc/os-release` is a regular file every systemd-based
  /// distribution ships), so unlike `currentArchitecture()` this isn't
  /// `async`.
  public static func currentSeries(osReleasePath: String = defaultOSReleasePath) -> String? {
    guard let contents = try? String(contentsOfFile: osReleasePath, encoding: .utf8) else {
      return nil
    }
    return OSReleaseParsing.versionCodename(fromContents: contents)
  }

  // MARK: - GitHub release lookup (same public API `UpdateChecker` already queries)

  /// The same public, versionless GitHub Releases API endpoint
  /// `UpdateChecker.releasesAPIURL` already queries — duplicated here
  /// (rather than reached into, across the `ClipnestViewModels` ->
  /// `ClipnestLinuxAppKit` module boundary) because that constant is
  /// `private` in a different module; the same "one cheap, documented
  /// duplicate" precedent `UInputPermissionChecker.defaultDevicePath`'s doc
  /// comment already uses for an identical situation.
  static let releasesAPIURL = "https://api.github.com/repos/AayushGour/clipnest/releases/latest"

  static let curlExecutablePath = "/usr/bin/curl"
  /// Bounds the small JSON/checksum-text fetches — same values
  /// `UpdateChecker.curlMaxTimeSeconds`/`curlConnectTimeoutSeconds` use, for
  /// the same reason (T-PF4: bound a stuck connection without punishing a
  /// merely-slow one). See `curlDownloadMaxTimeSeconds` below for why the
  /// actual `.deb` download needs a much larger ceiling.
  public static let curlMaxTimeSeconds = 10
  public static let curlConnectTimeoutSeconds = 5
  /// Bounds the `.deb` binary download specifically — a real package is
  /// tens of megabytes, not the few kilobytes of JSON/checksum text the
  /// constants above are sized for; `--connect-timeout` stays tight (a
  /// genuinely unreachable host should still fail fast), only the overall
  /// transfer ceiling grows.
  public static let curlDownloadMaxTimeSeconds = 180
  public static let curlDownloadConnectTimeoutSeconds = 5

  /// Pure — mirrors `UpdateChecker.curlArguments(for:)` exactly (same
  /// `-fsSL` flags: fail on HTTP errors, silent, show errors, follow
  /// redirects), parameterized so the same helper serves both the small
  /// JSON/checksum fetches and the much larger `.deb` download.
  public static func curlArguments(
    for urlString: String,
    maxTimeSeconds: Int = curlMaxTimeSeconds,
    connectTimeoutSeconds: Int = curlConnectTimeoutSeconds
  ) -> [String] {
    [
      "--max-time", String(maxTimeSeconds),
      "--connect-timeout", String(connectTimeoutSeconds),
      // https only, including across redirects (a downgrade to http would
      // let a network attacker swap the .deb/checksum pair).
      "--proto", "=https", "--proto-redir", "=https",
      "-fsSL", urlString,
    ]
  }

  /// One GitHub release asset — just the two fields this file needs
  /// (`assets[].name`/`assets[].browser_download_url`).
  public struct GitHubReleaseAsset: Equatable, Sendable {
    public let name: String
    public let browserDownloadURL: String
  }

  /// Pure JSON parsing (`JSONSerialization`, a real parser — same reasoning
  /// `UpdateChecker.parseTagName(fromReleaseJSON:)`'s doc comment gives for
  /// preferring it over a bash-style regex) and pure asset-selection logic,
  /// unit-tested directly against fixture JSON/arrays.
  public enum ReleaseAssetParsing {
    /// Duplicated from `UpdateChecker.parseTagName(fromReleaseJSON:)` —
    /// same "cheap, documented duplicate across a module boundary"
    /// precedent as `releasesAPIURL` above; that method is `public` but
    /// lives on `UpdateChecker`, an unrelated type in a different module
    /// this file has no other reason to depend on.
    public static func tagName(fromReleaseJSON data: Data) -> String? {
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tag = object["tag_name"] as? String
      else { return nil }
      return tag
    }

    public static func assets(fromReleaseJSON data: Data) -> [GitHubReleaseAsset] {
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let rawAssets = object["assets"] as? [[String: Any]]
      else { return [] }
      return rawAssets.compactMap { raw in
        guard let name = raw["name"] as? String,
          let url = raw["browser_download_url"] as? String
        else { return nil }
        return GitHubReleaseAsset(name: name, browserDownloadURL: url)
      }
    }

    /// Matches `release-linux.yml`'s own naming
    /// (`<package>_<version>_<arch>-<series>.deb`, e.g.
    /// `clipnest_0.9.1_arm64-jammy.deb`) WITHOUT hardcoding the version —
    /// `hasPrefix("\(packageName)_")` also correctly excludes
    /// `clipnest-ocr_…`/`clipnest-ocr-data_…` (those start with
    /// `"clipnest-ocr_"`, not `"clipnest_"`), so this never accidentally
    /// selects a sibling package's asset.
    public static func selectDebAsset(
      from assets: [GitHubReleaseAsset], packageName: String, architecture: String, series: String
    ) -> GitHubReleaseAsset? {
      let prefix = "\(packageName)_"
      let suffix = "_\(architecture)-\(series).deb"
      return assets.first { $0.name.hasPrefix(prefix) && $0.name.hasSuffix(suffix) }
    }

    /// `release-linux.yml` publishes `<deb-name>.sha256` as a sibling asset
    /// — same `<dmg>.sha256` convention `release.yml`'s macOS `.dmg`
    /// checksum already established.
    public static func checksumAssetName(forDebAssetName debAssetName: String) -> String {
      "\(debAssetName).sha256"
    }
  }

  /// Pure parsing of a `shasum -a 256`-format checksum file
  /// (`"<64-hex-lowercase>  <filename>"`) — the exact format
  /// `release-linux.yml`'s "Checksum + stage the .debs for upload" step
  /// writes, and the same format `release.yml`'s macOS `.dmg.sha256`
  /// already uses.
  public enum ChecksumFileParsing {
    public static func expectedHexDigest(fromContents contents: String) -> String? {
      guard
        let firstToken = contents.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
          .first
      else { return nil }
      let hex = firstToken.lowercased()
      guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
      return hex
    }
  }

  // MARK: - Download + verify + install (only reached for `.standaloneDebInstall`)

  /// Runs the whole "check the latest release, download the matching
  /// `.deb`, verify its checksum, install via `pkexec apt-get install`"
  /// flow — only ever called by `SettingsWindow+General.swift` after its
  /// own explicit "Install Update…" confirmation dialog (see this file's
  /// top doc comment: never automatic).
  ///
  /// `onStep` may be invoked from ANY thread (this whole function runs off
  /// the GTK thread) — the real call site
  /// (`SettingsWindow+General.swift`) hops back via `Task { @MainActor in
  /// ... }` before touching any widget, mirroring
  /// `GrantInputHelperClient.requestGrant(completion:)`'s identical
  /// contract.
  ///
  /// Checksum verification (`.verifyingChecksum`) always runs, and a
  /// mismatch (or a release with no published checksum at all) always
  /// aborts BEFORE `pkexec` is ever invoked — see this file's top doc
  /// comment for why a matching size/HTTP-200 is never treated as
  /// verification.
  public static func performUpdate(
    installedVersion: String,
    packageName: String = packageName,
    onStep: @escaping @Sendable (LinuxUpdateStep) -> Void
  ) async -> LinuxUpdateOutcome {
    onStep(.checkingLatestRelease)
    guard
      let releaseData = await runCapturingStdout(
        executablePath: curlExecutablePath, arguments: curlArguments(for: releasesAPIURL))
    else {
      return .failed(.noReleaseFound)
    }
    guard let tag = ReleaseAssetParsing.tagName(fromReleaseJSON: releaseData) else {
      return .failed(.noReleaseFound)
    }
    let latestVersion = UpdateChecker.normalizedVersion(fromTag: tag)
    guard UpdateChecker.isUpdateAvailable(installed: installedVersion, latestTag: tag) else {
      return .upToDate
    }

    guard let architecture = await currentArchitecture(), let series = currentSeries() else {
      return .failed(.noMatchingAssetFound)
    }
    let assets = ReleaseAssetParsing.assets(fromReleaseJSON: releaseData)
    guard
      let debAsset = ReleaseAssetParsing.selectDebAsset(
        from: assets, packageName: packageName, architecture: architecture, series: series)
    else {
      return .failed(.noMatchingAssetFound)
    }
    let checksumAssetName = ReleaseAssetParsing.checksumAssetName(forDebAssetName: debAsset.name)
    guard let checksumAsset = assets.first(where: { $0.name == checksumAssetName }) else {
      return .failed(.noChecksumPublished)
    }

    onStep(.downloadingUpdate)
    guard
      let checksumData = await runCapturingStdout(
        executablePath: curlExecutablePath,
        arguments: curlArguments(for: checksumAsset.browserDownloadURL)),
      let checksumText = String(data: checksumData, encoding: .utf8),
      let expectedDigest = ChecksumFileParsing.expectedHexDigest(fromContents: checksumText)
    else {
      return .failed(.noChecksumPublished)
    }

    guard
      let debData = await runCapturingStdout(
        executablePath: curlExecutablePath,
        arguments: curlArguments(
          for: debAsset.browserDownloadURL,
          maxTimeSeconds: curlDownloadMaxTimeSeconds,
          connectTimeoutSeconds: curlDownloadConnectTimeoutSeconds))
    else {
      return .failed(.downloadFailed("curl could not download \(debAsset.name)"))
    }

    onStep(.verifyingChecksum)
    // The one canonical SHA-256-hex helper (`ClipnestCore`) — see this
    // file's top doc comment for why this is not a second implementation.
    let actualDigest = BlobStore.contentHash(of: debData)
    guard actualDigest == expectedDigest else {
      return .failed(.checksumMismatch)
    }

    // Hand the .deb to the privileged helper on STDIN (an open fd), never as a
    // path: see `clipnest-install-update`'s security note. The helper re-hashes
    // its own root-owned copy, so a same-user process swapping bytes while the
    // polkit dialog is up cannot get anything but the verified .deb installed.
    let stdinHandle: FileHandle
    do {
      stdinHandle = try privateStdinHandle(for: debData)
    } catch {
      return .failed(.downloadFailed("could not save the download: \(error.localizedDescription)"))
    }
    defer { try? stdinHandle.close() }

    onStep(.installing)
    switch await runPkexecInstallUpdate(digest: expectedDigest, debInput: stdinHandle) {
    case .success:
      return .succeeded(installedVersion: latestVersion)
    case .cancelled:
      return .failed(.installationCancelled)
    case .failed(let message):
      return .failed(.installationFailed(message))
    }
  }

  // MARK: - Privileged install (`pkexec clipnest-install-update`)

  /// Fixed path of the root helper; bound to the `app.clipnest.install-update`
  /// polkit action by its `org.freedesktop.policykit.exec.path` annotation.
  public static let installHelperPath = "/usr/libexec/clipnest/clipnest-install-update"

  /// True only for exactly 64 lowercase hex characters — the format the helper
  /// also enforces (`^[0-9a-f]{64}$`), so a malformed digest never reaches argv.
  public static func isValidSHA256Hex(_ digest: String) -> Bool {
    digest.utf8.count == 64
      && digest.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
  }

  /// Pure — argv for `pkexec`: just the helper and the expected digest. Returns
  /// `nil` for an invalid digest. The .deb itself goes on stdin, not argv.
  public static func pkexecInstallUpdateArguments(
    digest: String, helperPath: String = installHelperPath
  ) -> [String]? {
    guard isValidSHA256Hex(digest) else { return nil }
    return [helperPath, digest]
  }

  /// Base directory for the short-lived private download file:
  /// `$XDG_RUNTIME_DIR` (per-user tmpfs, 0700) else `$XDG_CACHE_HOME`/
  /// `~/.cache`. Never the shared `/tmp`.
  static func privateBaseDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
      return URL(fileURLWithPath: runtime, isDirectory: true)
    }
    if let cache = environment["XDG_CACHE_HOME"], cache.hasPrefix("/") {
      return URL(fileURLWithPath: cache, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cache", isDirectory: true)
  }

  /// Writes `data` to a fresh 0700 dir / 0600 file, opens it for reading, then
  /// unlinks both immediately — only the open fd survives, to be used as the
  /// helper's stdin. Not a security boundary on its own (a same-user process can
  /// still reach the inode); the helper's root-side re-hash is.
  static func privateStdinHandle(
    for data: Data, base: URL = privateBaseDirectory()
  ) throws -> FileHandle {
    let fm = FileManager.default
    let dir = base.appendingPathComponent("clipnest-update-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(
      at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: dir) }
    let file = dir.appendingPathComponent("update.deb")
    guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    return try FileHandle(forReadingFrom: file)
  }

  private enum InstallProcessResult {
    case success
    case cancelled
    case failed(String)
  }

  /// Runs `pkexec clipnest-install-update <sha256>` (deb on stdin) on a background queue.
  ///
  /// Exit-code handling is based on `pkexec(1)`'s OWN documented contract
  /// (freedesktop.org/Ubuntu manpages, verified for real rather than
  /// assumed — see this task's own verification log), not
  /// `GrantInputHelperClient`'s doc comment (which describes a DIFFERENT
  /// custom helper script's exit codes, not bare `pkexec`'s): "if the
  /// calling process is not authorized, or an authorization could not be
  /// obtained through authentication, or the authentication dialog was
  /// dismissed, pkexec exits with a return value of 126" — verified
  /// directly in a real container by running `pkexec` as a non-root user
  /// with no authentication agent available. Every other non-zero exit
  /// (including the ALSO-empirically-observed 127 for "no authentication
  /// agent could even be started" in a headless container — genuinely
  /// ambiguous with "pkexec/the target program itself could not be run")
  /// is surfaced as a generic failure with whatever `pkexec`/`apt-get`
  /// actually printed to stderr, which is already the more specific,
  /// correct explanation in every case — same principle
  /// `GrantInputHelperClient.requestGrant(completion:)`'s doc comment
  /// states for its own exit-code handling.
  private static func runPkexecInstallUpdate(
    digest: String, debInput: FileHandle
  ) async -> InstallProcessResult {
    await withCheckedContinuation { continuation in
      processQueue.async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GrantInputHelperClient.pkexecExecutablePath)
        guard let arguments = pkexecInstallUpdateArguments(digest: digest) else {
          continuation.resume(returning: .failed("Invalid checksum format."))
          return
        }
        process.arguments = arguments
        process.standardInput = debInput
        // One pipe for both streams: reading them one after the other could
        // deadlock if the child fills the other pipe's 64 KB buffer.
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout

        do {
          try process.run()
        } catch {
          continuation.resume(
            returning: .failed(
              "Could not run pkexec (\(error.localizedDescription)). Is polkit installed?"))
          return
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = Data()  // stderr is merged into `outputData`
        process.waitUntilExit()

        switch process.terminationStatus {
        case 0:
          continuation.resume(returning: .success)
        case 126:
          continuation.resume(returning: .cancelled)
        case installHelperNotNewerExitCode:
          continuation.resume(
            returning: .failed(
              "This update is not newer than the version you already have, so it was not installed."
            ))
        default:
          let errorText = Self.decodedTrimmed(errorData)
          let outputText = Self.decodedTrimmed(outputData)
          let reason =
            !errorText.isEmpty
            ? errorText
            : (!outputText.isEmpty
              ? outputText : "pkexec exited with status \(process.terminationStatus).")
          continuation.resume(returning: .failed(reason))
        }
      }
    }
  }

  /// `clipnest-install-update` exit status for "not newer than installed"
  /// (anti-downgrade; keep in sync with `EXIT_NOT_NEWER` in the script).
  private static let installHelperNotNewerExitCode: Int32 = 3

  private static func decodedTrimmed(_ data: Data) -> String {
    (String(data: data, encoding: .utf8) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Shared `Process` plumbing

  /// Dedicated serial queue Swift Concurrency does not own — same T-PF4
  /// pattern `UpdateChecker.processQueue`/
  /// `GrantInputHelperClient.processQueue` already use, for the identical
  /// reason: keeps every blocking `Process.run()`/`readDataToEndOfFile()`/
  /// `waitUntilExit()` sequence below off both the GTK thread and the
  /// Swift Concurrency cooperative thread pool.
  private static let processQueue = DispatchQueue(
    label: "com.clipnest.linuxappupdater.processQueue", qos: .utility)

  /// Spawns `executablePath` with `arguments` and returns its captured
  /// stdout, or `nil` on any failure (missing binary, non-zero exit —
  /// including a `--max-time`/`--connect-timeout` timeout for the `curl`
  /// call sites above). Mirrors
  /// `UpdateChecker.fetchLatestReleaseJSON()`'s exact
  /// `withCheckedContinuation`-bridged pattern, generalized to the several
  /// call sites in this file that need the identical shape (`apt-cache
  /// policy`, `dpkg --print-architecture`, the two `curl` fetches).
  private static func runCapturingStdout(executablePath: String, arguments: [String]) async
    -> Data?
  {
    await withCheckedContinuation { continuation in
      processQueue.async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
          try process.run()
        } catch {
          continuation.resume(returning: nil)
          return
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: data)
      }
    }
  }
}

/// Parses `apt-cache policy <package>`'s "Version table" to decide whether
/// the INSTALLED version is served by any configured apt origin, or only by
/// dpkg's own local status database (i.e. no repository owns it).
///
/// Verified for real (not assumed) in a throwaway `ubuntu:22.04` container:
/// a plain `dpkg -i` install of a package with no apt source configured for
/// it reports exactly:
/// ```
/// clipnest:
///   Installed: 0.9.1
///   Candidate: 0.9.1
///   Version table:
///  *** 0.9.1 100
///         100 /var/lib/dpkg/status
/// ```
/// Adding a local `file:` apt repository serving the same package (a stand-in
/// for a real PPA — `apt-cache`'s parsing has no notion of "PPA" specifically,
/// only "does some configured origin serve this version") changes ONLY the
/// installed version's origin list, prepending a second, higher-priority line
/// ahead of the same local-status line:
/// ```
///  *** 0.9.1 500
///         500 file:/tmp/repo jammy/main arm64 Packages
///         100 /var/lib/dpkg/status
/// ```
/// So the distinguishing signal is: does the STARRED (installed) version's
/// block contain any origin line other than the literal
/// `/var/lib/dpkg/status`? The indentation above is real `apt-cache`
/// output, not a guess: the `***`-prefixed line has ONE leading space,
/// every origin line under it has EIGHT, and an UNINSTALLED candidate
/// version further down (e.g. `     0.9.0 500`) has FIVE — more than the
/// installed line's own one space, but a different kind of line, not an
/// origin. This parser therefore does NOT use "more indented than the
/// installed line" to collect origins (that would misread the next
/// version entry as an origin); it anchors on the indentation of the FIRST
/// line immediately following the installed one and consumes only further
/// lines matching that exact indentation, stopping the moment it changes
/// in either direction — degrading gracefully to `.undetermined` if a
/// future apt version reformats the exact spacing.
public enum AptPolicyParsing {
  /// The literal origin `apt-cache policy` reports for a version known only
  /// to dpkg's local status database, never a configured apt source — see
  /// this type's own doc comment for the verified transcript.
  public static let dpkgStatusOrigin = "/var/lib/dpkg/status"

  public static func provenance(fromPolicyOutput output: String) -> LinuxUpdateProvenance {
    let lines = output.components(separatedBy: "\n")
    guard
      let installedLineIndex = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("*** ")
      })
    else {
      return .undetermined(reason: "apt-cache policy reported no installed version")
    }

    // The origin lines under the installed version share ONE fixed
    // indentation (8 spaces in every real capture — see this type's doc
    // comment), but that indentation is NOT simply "more than the
    // installed line's own indent (1)": a FOLLOWING, uninstalled version
    // entry (e.g. `     0.9.0 500`) is indented 5 spaces — more than 1, but
    // NOT an origin line. Comparing against the installed line's own
    // indent would misread that next version entry as an origin (and, via
    // its version-then-priority shape, as a fabricated non-dpkg-status
    // "origin"). Instead this anchors on the FIRST line's own indentation
    // and only consumes further lines that match it exactly, stopping the
    // moment indentation changes in EITHER direction — which correctly
    // captures multiple origin lines (all equally indented) while stopping
    // at the very next version entry, whichever way its indentation
    // differs.
    var index = installedLineIndex + 1
    guard index < lines.count else {
      return .undetermined(reason: "apt-cache policy reported no origins for the installed version")
    }
    let firstOriginLine = lines[index]
    let firstOriginTrimmed = firstOriginLine.trimmingCharacters(in: .whitespaces)
    guard !firstOriginTrimmed.isEmpty else {
      return .undetermined(reason: "apt-cache policy reported no origins for the installed version")
    }
    let originIndent = firstOriginLine.prefix(while: { $0 == " " }).count

    var originLines: [String] = []
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let indent = line.prefix(while: { $0 == " " }).count
      guard !trimmed.isEmpty, indent == originIndent else { break }
      originLines.append(trimmed)
      index += 1
    }

    guard !originLines.isEmpty else {
      return .undetermined(reason: "apt-cache policy reported no origins for the installed version")
    }

    for line in originLines {
      guard let spaceIndex = line.firstIndex(of: " ") else { continue }
      let origin = String(line[line.index(after: spaceIndex)...])
        .trimmingCharacters(in: .whitespaces)
      if origin != dpkgStatusOrigin {
        return .packageManaged(origin: origin)
      }
    }
    return .standaloneDebInstall
  }
}
