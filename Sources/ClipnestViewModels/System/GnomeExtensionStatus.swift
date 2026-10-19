import Foundation

/// Where Clipnest's per-user GNOME Shell extension stands, as the first-run
/// welcome window (and anything else that cares) should present it.
///
/// Lives in `ClipnestViewModels` (not the Linux app kit) so `ClipnestGTK`'s
/// welcome window can consume it. Produced on Linux by
/// `GnomeExtensionStatus.resolve(install:shellHelperPresent:)` from
/// `GnomeExtensionInstaller.run()` plus live `app.clipnest.ShellHelper` D-Bus
/// presence, and exposed as `LinuxAppEnvironment.gnomeExtensionStatus`.
public enum GnomeExtensionStatus: Equatable, Sendable {
  /// The install check has not finished yet (it runs off the GTK thread).
  case checking
  /// Not a GNOME session (`XDG_CURRENT_DESKTOP`): nothing to install, and
  /// nothing to tell the user.
  case unsupportedDesktop
  /// The Shell is running the extension (`app.clipnest.ShellHelper` owns its
  /// bus name) and no new files were written this launch.
  case active
  /// Installed or refreshed on disk and enabled in `org.gnome.shell`, but the
  /// running Shell is not (yet) serving it. Wayland cannot load a new
  /// extension, or new code for a loaded one, without a log out, so the user
  /// should "log out once to finish setup".
  case installedNeedsRelogin
  /// The user turned the extension off themselves (it is listed in
  /// `disabled-extensions`, or Clipnest enabled it earlier and it has since
  /// been removed from `enabled-extensions`). Clipnest respects that and
  /// never re-enables it.
  case disabledByUser
  /// `org.gnome.shell disable-user-extensions` is true: GNOME loads no
  /// per-user extension at all. Reported, never flipped.
  case userExtensionsDisabled
  /// The install could not be completed; `reason` is a short human-readable
  /// explanation (also logged).
  case failed(reason: String)
}
