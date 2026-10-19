import ClipnestViewModels
import Foundation

extension GnomeExtensionStatus {
  /// Combines the one-time install result with live Shell presence. Pure.
  ///
  /// A running extension wins over everything except "files changed this
  /// launch": the loaded code is then the previous version's, so a re-login
  /// is still pending.
  static func resolve(
    install: GnomeExtensionInstallResult?, shellHelperPresent: Bool
  ) -> GnomeExtensionStatus {
    guard let install else { return .checking }
    switch install {
    case .unsupportedDesktop:
      return .unsupportedDesktop
    case .failed(let reason):
      return shellHelperPresent ? .active : .failed(reason: reason)
    case .userExtensionsDisabled:
      return .userExtensionsDisabled
    case .disabledByUser:
      return shellHelperPresent ? .active : .disabledByUser
    case .ready(let filesChanged):
      if shellHelperPresent && !filesChanged { return .active }
      return .installedNeedsRelogin
    }
  }
}

/// What `GnomeExtensionInstaller.run()` did, before live D-Bus presence is
/// folded in.
public enum GnomeExtensionInstallResult: Equatable, Sendable {
  case unsupportedDesktop
  case failed(reason: String)
  case userExtensionsDisabled
  case disabledByUser
  /// Files are in place and the uuid is enabled; `filesChanged` is true when
  /// this launch freshly installed or replaced them.
  case ready(filesChanged: Bool)
}
