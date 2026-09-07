import Foundation
import Testing

@testable import ClipnestGTK
@testable import ClipnestLinuxAppKit

/// T-LXUPD: `LinuxAppUpdater` — see that type's own doc comment for the
/// overall design. This suite covers every PURE decision (argument
/// construction, JSON/text parsing, asset selection, the `apt-cache policy`
/// provenance parser) directly, mirroring `AppGrantInputHelperClientTests`/
/// `AppUInputPermissionCheckerTests`'s identical "pure logic unit-tested,
/// real process spawns integration-verified separately" split. The real
/// `apt-cache`/`curl`/`pkexec` process spawns are exercised for real only
/// where this bare container makes that a genuine, honest exercise (see
/// the dedicated real-process tests below) — full end-to-end
/// download+install needs a real network + a real polkit authentication
/// agent, neither of which exist here, and is manual/container-verified
/// separately (see this task's own verification log).
@Suite("LinuxAppUpdater")
struct AppLinuxAppUpdaterTests {

  // MARK: - AptPolicyParsing — real, captured `apt-cache policy` transcripts

  @Test("A raw .deb install (no configured apt source) is standalone")
  func rawDebInstallIsStandalone() {
    // Captured verbatim from a real `ubuntu:22.04` container: `dpkg -i` a
    // throwaway "clipnest" package with no apt source configured for it.
    let output = """
      clipnest:
        Installed: 0.9.1
        Candidate: 0.9.1
        Version table:
       *** 0.9.1 100
              100 /var/lib/dpkg/status
      """
    #expect(AptPolicyParsing.provenance(fromPolicyOutput: output) == .standaloneDebInstall)
  }

  @Test("An apt-repository-managed install (PPA stand-in) is packageManaged with the real origin")
  func repoManagedInstallIsPackageManaged() {
    // Same container, same package, after adding a local `file:` apt
    // source serving the identical version — `apt-cache`'s own parsing has
    // no notion of "PPA" specifically, only "does some configured origin
    // serve this version," so a local repo is a faithful stand-in.
    let output = """
      clipnest:
        Installed: 0.9.1
        Candidate: 0.9.1
        Version table:
       *** 0.9.1 500
              500 file:/tmp/repo jammy/main arm64 Packages
              100 /var/lib/dpkg/status
      """
    #expect(
      AptPolicyParsing.provenance(fromPolicyOutput: output)
        == .packageManaged(origin: "file:/tmp/repo jammy/main arm64 Packages"))
  }

  @Test("A real PPA-shaped origin line is reported verbatim")
  func realPPAShapedOriginIsReportedVerbatim() {
    let output = """
      clipnest:
        Installed: 0.9.1
        Candidate: 0.9.1
        Version table:
       *** 0.9.1 500
              500 http://ppa.launchpad.net/aayushgour/clipnest/ubuntu jammy/main amd64 Packages
              100 /var/lib/dpkg/status
      """
    #expect(
      AptPolicyParsing.provenance(fromPolicyOutput: output)
        == .packageManaged(
          origin: "http://ppa.launchpad.net/aayushgour/clipnest/ubuntu jammy/main amd64 Packages"))
  }

  @Test("A package apt-cache has never heard of is undetermined, not standalone")
  func unknownPackageIsUndeterminedNotStandalone() {
    let output = "N: Unable to locate package clipnest\n"
    guard case .undetermined = AptPolicyParsing.provenance(fromPolicyOutput: output) else {
      Issue.record("Expected .undetermined for a package apt-cache reports no version table for")
      return
    }
  }

  @Test("Empty output is undetermined")
  func emptyOutputIsUndetermined() {
    guard case .undetermined = AptPolicyParsing.provenance(fromPolicyOutput: "") else {
      Issue.record("Expected .undetermined for empty output")
      return
    }
  }

  @Test("Multiple candidate versions: only the starred (installed) block's origins matter")
  func onlyInstalledVersionBlockIsConsidered() {
    // A repo serves an OLDER version than what's actually installed (e.g. a
    // manually-installed newer .deb while the configured repo still has an
    // old one) — the installed version's own block has only the local
    // status origin, so this must still be standalone, not package-managed,
    // even though the file below contains a real repo URI further down.
    let output = """
      clipnest:
        Installed: 0.9.1
        Candidate: 0.9.0
        Version table:
       *** 0.9.1 100
              100 /var/lib/dpkg/status
           0.9.0 500
              500 http://ppa.launchpad.net/aayushgour/clipnest/ubuntu jammy/main amd64 Packages
      """
    #expect(AptPolicyParsing.provenance(fromPolicyOutput: output) == .standaloneDebInstall)
  }

  // MARK: - OSReleaseParsing

  @Test("Quoted VERSION_CODENAME is unquoted")
  func quotedVersionCodenameIsUnquoted() {
    let contents = "NAME=\"Ubuntu\"\nVERSION_CODENAME=\"jammy\"\nID=ubuntu\n"
    #expect(LinuxAppUpdater.OSReleaseParsing.versionCodename(fromContents: contents) == "jammy")
  }

  @Test("Unquoted VERSION_CODENAME passes through")
  func unquotedVersionCodenamePassesThrough() {
    let contents = "NAME=Ubuntu\nVERSION_CODENAME=noble\n"
    #expect(LinuxAppUpdater.OSReleaseParsing.versionCodename(fromContents: contents) == "noble")
  }

  @Test("Missing VERSION_CODENAME is nil")
  func missingVersionCodenameIsNil() {
    let contents = "NAME=Ubuntu\nID=ubuntu\n"
    #expect(LinuxAppUpdater.OSReleaseParsing.versionCodename(fromContents: contents) == nil)
  }

  @Test("currentSeries(osReleasePath:) reads a real injected fixture file")
  func currentSeriesReadsInjectedFixture() throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("os-release-fixture-\(UUID().uuidString)").path
    try "VERSION_CODENAME=jammy\n".write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(LinuxAppUpdater.currentSeries(osReleasePath: path) == "jammy")
  }

  @Test("currentSeries(osReleasePath:) is nil for a nonexistent path")
  func currentSeriesNilForMissingFile() {
    let path = "/nonexistent/\(UUID().uuidString)/os-release"
    #expect(LinuxAppUpdater.currentSeries(osReleasePath: path) == nil)
  }

  // MARK: - ReleaseAssetParsing

  private func releaseJSON(assets: [(name: String, url: String)] = [], tag: String = "v0.9.1")
    -> Data
  {
    let assetsJSON = assets.map {
      "{\"name\": \"\($0.name)\", \"browser_download_url\": \"\($0.url)\"}"
    }
    .joined(separator: ",")
    let json = "{\"tag_name\": \"\(tag)\", \"assets\": [\(assetsJSON)]}"
    return Data(json.utf8)
  }

  @Test("tagName parses a real GitHub Releases API shape")
  func tagNameParsesRealShape() {
    #expect(LinuxAppUpdater.ReleaseAssetParsing.tagName(fromReleaseJSON: releaseJSON()) == "v0.9.1")
  }

  @Test("tagName is nil for malformed JSON")
  func tagNameNilForMalformedJSON() {
    #expect(
      LinuxAppUpdater.ReleaseAssetParsing.tagName(fromReleaseJSON: Data("not json".utf8)) == nil)
  }

  @Test("assets extracts name + browser_download_url pairs, skipping malformed entries")
  func assetsExtractsPairs() {
    let json = releaseJSON(assets: [
      ("clipnest_0.9.1_arm64-jammy.deb", "https://example.com/a.deb"),
      ("clipnest_0.9.1_arm64-jammy.deb.sha256", "https://example.com/a.deb.sha256"),
    ])
    let assets = LinuxAppUpdater.ReleaseAssetParsing.assets(fromReleaseJSON: json)
    #expect(assets.count == 2)
    #expect(assets[0].name == "clipnest_0.9.1_arm64-jammy.deb")
    #expect(assets[0].browserDownloadURL == "https://example.com/a.deb")
  }

  @Test("selectDebAsset matches the exact package/arch/series shape release-linux.yml publishes")
  func selectDebAssetMatchesRealNamingShape() {
    let assets: [LinuxAppUpdater.GitHubReleaseAsset] = [
      .init(name: "clipnest_0.9.1_arm64-jammy.deb", browserDownloadURL: "https://x/1"),
      .init(name: "clipnest_0.9.1_amd64-jammy.deb", browserDownloadURL: "https://x/2"),
      .init(name: "clipnest_0.9.1_arm64-noble.deb", browserDownloadURL: "https://x/3"),
    ]
    let selected = LinuxAppUpdater.ReleaseAssetParsing.selectDebAsset(
      from: assets, packageName: "clipnest", architecture: "arm64", series: "jammy")
    #expect(selected?.name == "clipnest_0.9.1_arm64-jammy.deb")
  }

  @Test("selectDebAsset never selects a sibling package's asset (clipnest-ocr, clipnest-ocr-data)")
  func selectDebAssetExcludesSiblingPackages() {
    let assets: [LinuxAppUpdater.GitHubReleaseAsset] = [
      .init(name: "clipnest-ocr_0.9.1_arm64-jammy.deb", browserDownloadURL: "https://x/1"),
      .init(name: "clipnest-ocr-data_0.9.1_all-jammy.deb", browserDownloadURL: "https://x/2"),
    ]
    let selected = LinuxAppUpdater.ReleaseAssetParsing.selectDebAsset(
      from: assets, packageName: "clipnest", architecture: "arm64", series: "jammy")
    #expect(selected == nil)
  }

  @Test("selectDebAsset returns nil when no asset matches this system")
  func selectDebAssetNilWhenNoMatch() {
    let assets: [LinuxAppUpdater.GitHubReleaseAsset] = [
      .init(name: "clipnest_0.9.1_amd64-jammy.deb", browserDownloadURL: "https://x/1")
    ]
    let selected = LinuxAppUpdater.ReleaseAssetParsing.selectDebAsset(
      from: assets, packageName: "clipnest", architecture: "arm64", series: "noble")
    #expect(selected == nil)
  }

  @Test("checksumAssetName appends .sha256, matching release-linux.yml's own convention")
  func checksumAssetNameAppendsSuffix() {
    #expect(
      LinuxAppUpdater.ReleaseAssetParsing.checksumAssetName(
        forDebAssetName: "clipnest_0.9.1_arm64-jammy.deb")
        == "clipnest_0.9.1_arm64-jammy.deb.sha256")
  }

  // MARK: - ChecksumFileParsing

  @Test("A real shasum-format line parses to its lowercase hex digest")
  func realShasumFormatParses() {
    let hex = String(repeating: "a1", count: 32)
    let contents = "\(hex)  clipnest_0.9.1_arm64-jammy.deb\n"
    #expect(LinuxAppUpdater.ChecksumFileParsing.expectedHexDigest(fromContents: contents) == hex)
  }

  @Test("Uppercase hex is normalized to lowercase")
  func uppercaseHexIsNormalized() {
    let contents = "\(String(repeating: "AB", count: 32))  file.deb\n"
    #expect(
      LinuxAppUpdater.ChecksumFileParsing.expectedHexDigest(fromContents: contents)
        == String(repeating: "ab", count: 32))
  }

  @Test("Wrong-length hex is rejected")
  func wrongLengthHexIsRejected() {
    #expect(
      LinuxAppUpdater.ChecksumFileParsing.expectedHexDigest(fromContents: "abcd  file.deb") == nil)
  }

  @Test("Non-hex first token is rejected")
  func nonHexFirstTokenIsRejected() {
    let contents = "not-a-hex-digest-at-all-not-a-hex-digest-at-all-not-a-hex-digest12  file.deb"
    #expect(LinuxAppUpdater.ChecksumFileParsing.expectedHexDigest(fromContents: contents) == nil)
  }

  @Test("Empty content is rejected")
  func emptyContentIsRejected() {
    #expect(LinuxAppUpdater.ChecksumFileParsing.expectedHexDigest(fromContents: "") == nil)
  }

  // MARK: - Pure argument construction

  @Test("aptCachePolicyArguments is exactly policy <package>")
  func aptCachePolicyArgumentsShape() {
    #expect(
      LinuxAppUpdater.aptCachePolicyArguments(packageName: "clipnest") == ["policy", "clipnest"])
  }

  @Test("aptUpgradeCommand names the real package and only ever upgrades it")
  func aptUpgradeCommandShape() {
    let command = LinuxAppUpdater.aptUpgradeCommand(packageName: "clipnest")
    #expect(command.contains("apt update"))
    #expect(command.contains("--only-upgrade clipnest"))
  }

  @Test("curlArguments bounds both connect and overall transfer time")
  func curlArgumentsAreBounded() {
    let args = LinuxAppUpdater.curlArguments(
      for: "https://example.com", maxTimeSeconds: 42, connectTimeoutSeconds: 7)
    #expect(args.contains("--max-time"))
    #expect(args.contains("42"))
    #expect(args.contains("--connect-timeout"))
    #expect(args.contains("7"))
    #expect(args.contains("https://example.com"))
  }

  @Test("pkexecAptGetInstallArguments installs the exact given path, non-interactively")
  func pkexecAptGetInstallArgumentsShape() {
    #expect(
      LinuxAppUpdater.pkexecAptGetInstallArguments(debPath: "/tmp/clipnest.deb")
        == ["apt-get", "install", "-y", "/tmp/clipnest.deb"])
  }

  @Test("The shipped package name constant matches debian/control")
  func packageNameConstantMatchesPackaging() {
    #expect(LinuxAppUpdater.packageName == "clipnest")
  }

  // MARK: - Real process spawns this bare container CAN exercise honestly

  @Test("detectProvenance against a package name that certainly doesn't exist is undetermined")
  func detectProvenanceForNonexistentPackageIsUndetermined() async throws {
    // Real, honest exercise of the actual `apt-cache` spawn (not a mock) —
    // mirrors `AppGrantInputHelperClientTests`'s identical "skip if this
    // container's own environment doesn't have the tool at all" guard.
    guard FileManager.default.fileExists(atPath: LinuxAppUpdater.aptCacheExecutablePath) else {
      return
    }
    let nonexistentPackage = "clipnest-test-nonexistent-package-\(UUID().uuidString.prefix(8))"
    let provenance = await LinuxAppUpdater.detectProvenance(packageName: nonexistentPackage)
    guard case .undetermined = provenance else {
      Issue.record("Expected .undetermined for a package that was never installed: \(provenance)")
      return
    }
  }

  @Test("currentArchitecture resolves to a real, non-empty value when dpkg exists")
  func currentArchitectureResolvesWhenDpkgExists() async throws {
    guard FileManager.default.fileExists(atPath: LinuxAppUpdater.dpkgExecutablePath) else {
      return
    }
    let architecture = await LinuxAppUpdater.currentArchitecture()
    #expect(!(architecture ?? "").isEmpty)
  }
}
