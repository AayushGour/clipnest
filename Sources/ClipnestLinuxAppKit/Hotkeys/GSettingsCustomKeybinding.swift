import CGtk4
import ClipnestCore
import Foundation

#if canImport(Glibc)
  import Glibc
#endif

/// Installs the tier-4 GSettings floor: a custom keybinding under
/// `org.gnome.settings-daemon.plugins.media-keys` invoking this app's own
/// CLI, at a NAMED path (never `customN` — see
/// `GSettingsKeybindingPath`'s doc comment). Real GIO/`GSettings` calls —
/// manual-verify only, since there is no `dconf`/GSettings daemon in the
/// CI container this ships to; `GSettingsKeybindingPath`'s path-building
/// (the part with real logic to get wrong) is unit-tested directly
/// instead.
enum GSettingsCustomKeybinding {
  /// T-HOTKEYGAP1 diagnostics: the floor's install result is the one fact
  /// that separates "Clipnest wrote the fallback keybinding" from
  /// "gnome-settings-daemon actually re-grabbed the accelerator" — see
  /// `InstallOutcome`'s doc comment. Metadata only (segment name +
  /// booleans); accelerators/commands are never user content.
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "GSettingsCustomKeybinding")

  /// - Parameters:
  ///   - name: the human-readable label GNOME Settings' own "Keyboard"
  ///     panel shows for this binding (so a curious user finds an entry
  ///     named "Clipnest — Toggle Picker," not a mystery unlabeled row).
  ///   - command: the full CLI invocation to run on activation — this
  ///     app's own binary with a flag `main.swift` recognizes and forwards
  ///     to the running instance via `SingleInstance.forwardArguments`.
  ///   - binding: the accelerator string in GTK's `gtk_accelerator_parse`
  ///     format (e.g. `"<Super><Shift>v"`).
  ///   - segment: the named path segment (e.g. `"clipnest-toggle"`).
  /// What `install` actually changed, so a caller can log the difference
  /// between "the floor was written" and "the floor was already exactly
  /// this and nothing was written".
  ///
  /// This distinction is the whole point (T-HOTKEYGAP1): gnome-settings-
  /// daemon's media-keys plugin re-grabs an accelerator when it sees a
  /// GSettings `changed` signal for that binding — a value-identical
  /// re-write may produce no `changed` signal and therefore no re-grab, so
  /// "install succeeded" and "gsd now holds the grab" are different facts
  /// and must not read the same in a log (coding-standards.md's
  /// unconfirmed-vs-confirmed rule).
  struct InstallOutcome: Equatable {
    /// `false` when the schemas/path were unavailable and nothing at all
    /// was attempted — distinct from "attempted and nothing needed to
    /// change".
    var applied: Bool
    /// Whether the `binding` key's value actually differed from what was
    /// already stored.
    var bindingChanged: Bool
    /// Whether this binding's path had to be appended to the media-keys
    /// `custom-keybindings` list.
    var listChanged: Bool

    static let notApplied = InstallOutcome(
      applied: false, bindingChanged: false, listChanged: false)

    var logDescription: String {
      "applied=\(applied) bindingChanged=\(bindingChanged) listChanged=\(listChanged)"
    }
  }

  static func install(name: String, command: String, binding: String, segment: String) {
    // Both schemas must exist BEFORE any g_settings_new* call — see
    // `schemaIsInstalled`: a missing schema aborts the process, it does not
    // return nil.
    guard schemaIsInstalled(MediaKeysSchema.mainSchemaID),
      schemaIsInstalled(MediaKeysSchema.customKeybindingSchemaID)
    else {
      logger.notice(
        "gsettings floor install: segment=\(segment) \(InstallOutcome.notApplied.logDescription) reason=schemaMissing"
      )
      return
    }
    guard let path = try? GSettingsKeybindingPath.path(forSegment: segment)
    else {
      logger.notice(
        "gsettings floor install: segment=\(segment) \(InstallOutcome.notApplied.logDescription) reason=badPath"
      )
      return
    }

    guard
      let perBinding = MediaKeysSchema.customKeybindingSchemaID.withCString({ schemaID in
        path.withCString { pathCString in g_settings_new_with_path(schemaID, pathCString) }
      })
    else {
      logger.notice(
        "gsettings floor install: segment=\(segment) \(InstallOutcome.notApplied.logDescription) reason=settingsUnavailable"
      )
      return
    }
    let previousBinding = readString(perBinding, key: MediaKeysSchema.bindingKey)
    setString(perBinding, key: MediaKeysSchema.nameKey, value: name)
    setString(perBinding, key: MediaKeysSchema.commandKey, value: command)
    setString(perBinding, key: MediaKeysSchema.bindingKey, value: binding)

    guard
      let main = MediaKeysSchema.mainSchemaID.withCString({ g_settings_new($0) })
    else {
      logger.notice(
        "gsettings floor install: segment=\(segment) "
          + InstallOutcome(
            applied: true, bindingChanged: previousBinding != binding, listChanged: false
          ).logDescription
          + " reason=mainSchemaUnavailable")
      return
    }
    var existing = readStringList(main, key: MediaKeysSchema.customKeybindingsListKey)
    var listChanged = false
    if !existing.contains(path) {
      existing.append(path)
      writeStringList(main, key: MediaKeysSchema.customKeybindingsListKey, values: existing)
      listChanged = true
    }
    logger.notice(
      "gsettings floor install: segment=\(segment) "
        + InstallOutcome(
          applied: true, bindingChanged: previousBinding != binding, listChanged: listChanged
        ).logDescription)
  }

  /// Whether a GSettings schema is actually installed on this machine.
  ///
  /// This check is NOT optional. `g_settings_new` and `g_settings_new_with_path`
  /// treat a missing schema as a PROGRAMMER ERROR and abort the process with
  /// `GLib-GIO-ERROR ** Settings schema '...' is not installed` — they do not
  /// return nil, so `guard let` provides no protection whatsoever. Found by
  /// running the app: on a bare X session with no GNOME settings-daemon
  /// installed, Clipnest died on launch before showing any UI.
  ///
  /// The GNOME media-keys schema is absent on KDE, XFCE, a plain WM session,
  /// and inside containers. The GSettings custom-keybinding hotkey tier simply
  /// does not apply there, and the app must fall through to another tier rather
  /// than abort.
  static func schemaIsInstalled(_ schemaID: String) -> Bool {
    guard let source = g_settings_schema_source_get_default() else { return false }
    guard let schema = schemaID.withCString({ g_settings_schema_source_lookup(source, $0, 1) })
    else { return false }
    g_settings_schema_unref(schema)
    return true
  }

  private static func setString(
    _ settings: UnsafeMutablePointer<GSettings>, key: String, value: String
  ) {
    key.withCString { keyCString in
      value.withCString { valueCString in
        _ = g_settings_set_string(settings, keyCString, valueCString)
      }
    }
  }

  private static func readString(
    _ settings: UnsafeMutablePointer<GSettings>, key: String
  ) -> String? {
    guard let cString = key.withCString({ g_settings_get_string(settings, $0) }) else { return nil }
    defer { g_free(cString) }
    return String(cString: cString)
  }

  private static func readStringList(
    _ settings: UnsafeMutablePointer<GSettings>, key: String
  ) -> [String] {
    guard let cArray = key.withCString({ g_settings_get_strv(settings, $0) }) else { return [] }
    defer { g_strfreev(cArray) }

    var result: [String] = []
    var index = 0
    while let entry = cArray[index] {
      result.append(String(cString: entry))
      index += 1
    }
    return result
  }

  private static func writeStringList(
    _ settings: UnsafeMutablePointer<GSettings>, key: String, values: [String]
  ) {
    #if canImport(Glibc)
      var duplicated: [UnsafeMutablePointer<CChar>?] = values.map { Glibc.strdup($0) }
      duplicated.append(nil)
      defer {
        for pointer in duplicated where pointer != nil {
          free(pointer)
        }
      }
      duplicated.withUnsafeMutableBufferPointer { buffer in
        buffer.baseAddress?.withMemoryRebound(
          to: UnsafePointer<CChar>?.self, capacity: buffer.count
        ) { rebound in
          _ = key.withCString { g_settings_set_strv(settings, $0, rebound) }
        }
      }
    #endif
  }
}
