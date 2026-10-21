import ClipnestViewModels

/// The welcome window's "Turn On" action for `GnomeExtensionStatus
/// .disabledByUser` (design.md "Step 1 - Linux", sub-row B).
///
/// `GnomeExtensionInstaller.run()` deliberately never re-enables an extension
/// the user turned off. A button press IS the user's explicit opt-back-in, so
/// this lifts that opt-out (removes the uuid from `disabled-extensions`,
/// re-adds it to `enabled-extensions`) and then re-runs the installer for the
/// fresh status. Consumes the installer's seams only; blocking (gsettings), so
/// call off the GTK thread.
enum GnomeExtensionTurnOn {
  static let writeFailureReason = "Could not turn on the GNOME extension (gsettings write failed)."
  static let unreadableReason = "Could not read GNOME's extension settings (gsettings unavailable)."

  static func run(installer: GnomeExtensionInstaller) -> GnomeExtensionInstallResult {
    let uuid = GnomeExtensionInstaller.uuid
    let disabledKey = GnomeExtensionInstaller.disabledExtensionsKey
    let enabledKey = GnomeExtensionInstaller.enabledExtensionsKey
    guard let disabled = installer.shell.stringList(forKey: disabledKey),
      let enabled = installer.shell.stringList(forKey: enabledKey)
    else { return .failed(reason: unreadableReason) }

    if disabled.contains(uuid) {
      let remaining = disabled.filter { $0 != uuid }
      guard installer.shell.setStringList(remaining, forKey: disabledKey) else {
        return .failed(reason: writeFailureReason)
      }
    }
    if !enabled.contains(uuid) {
      guard installer.shell.setStringList(enabled + [uuid], forKey: enabledKey) else {
        return .failed(reason: writeFailureReason)
      }
    }
    installer.files.recordEnabled()
    return installer.run()
  }
}
