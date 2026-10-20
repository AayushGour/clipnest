// UpdateCommand.swift
//
// Pure (no I/O) builder for the macOS in-app updater's Terminal command.
// Lives here rather than in `ClipnestApp/Sources/System/AppUpdater.swift` so
// the security-relevant parts (tag validation, URL + command construction)
// are unit-testable via SwiftPM.
//
// Security (T-AUD-UPDPIN): the updater used to run
// `curl .../main/scripts/update.sh | bash` — code from the mutable `main`
// branch executing on every updating Mac. It now fetches `update.sh` from the
// immutable-ish release TAG being installed, and passes that same tag to the
// script (`CLIPNEST_VERSION`) so it installs exactly that release. The tag is
// validated against a strict `^v\d+\.\d+\.\d+$` (ASCII digits only) BEFORE it
// is placed in any URL or command line, so it can't carry shell
// metacharacters. An invalid/absent tag yields `nil` — callers must NOT fall
// back to `main`.

import Foundation

public enum UpdateCommand {
  /// Environment variable `scripts/update.sh` reads to pin the version.
  public static let versionEnvVar = "CLIPNEST_VERSION"

  /// Base of the per-tag raw script URL (`<base>/<tag>/scripts/update.sh`).
  static let rawBaseURL = "https://raw.githubusercontent.com/AayushGour/clipnest"

  /// Hardening flags shared by every curl invocation: HTTPS only (including
  /// redirects), TLS 1.2+. Mirrors `CURL_SEC` in scripts/install.sh.
  static let curlSecurityFlags = "--proto '=https' --proto-redir '=https' --tlsv1.2"

  /// `"1.4.1"` or `"v1.4.1"` -> `"v1.4.1"`; `nil` unless it is exactly
  /// `v<digits>.<digits>.<digits>` with ASCII digits (equivalent to
  /// `^v\d+\.\d+\.\d+$`, without Unicode-digit or trailing-newline pitfalls).
  public static func validatedTag(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let tag = raw.hasPrefix("v") ? raw : "v" + raw
    let body = tag.dropFirst()
    let parts = body.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    for part in parts {
      guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
        return nil
      }
    }
    return tag
  }

  /// URL of `update.sh` pinned to `tag`; `nil` if `tag` is invalid.
  public static func scriptURL(forTag raw: String?) -> String? {
    guard let tag = validatedTag(raw) else { return nil }
    return "\(rawBaseURL)/\(tag)/scripts/update.sh"
  }

  /// The one-liner run in Terminal; `nil` if `tag` is invalid.
  public static func command(forTag raw: String?) -> String? {
    guard let tag = validatedTag(raw), let url = scriptURL(forTag: tag) else { return nil }
    return "curl \(curlSecurityFlags) -fsSL \(url) | \(versionEnvVar)=\(tag) bash"
  }
}
