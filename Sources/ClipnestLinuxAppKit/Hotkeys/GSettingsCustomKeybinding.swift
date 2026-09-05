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
  static func install(name: String, command: String, binding: String, segment: String) {
    guard let path = try? GSettingsKeybindingPath.path(forSegment: segment) else { return }

    guard
      let perBinding = MediaKeysSchema.customKeybindingSchemaID.withCString({ schemaID in
        path.withCString { pathCString in g_settings_new_with_path(schemaID, pathCString) }
      })
    else { return }
    setString(perBinding, key: MediaKeysSchema.nameKey, value: name)
    setString(perBinding, key: MediaKeysSchema.commandKey, value: command)
    setString(perBinding, key: MediaKeysSchema.bindingKey, value: binding)

    guard
      let main = MediaKeysSchema.mainSchemaID.withCString({ g_settings_new($0) })
    else { return }
    var existing = readStringList(main, key: MediaKeysSchema.customKeybindingsListKey)
    if !existing.contains(path) {
      existing.append(path)
      writeStringList(main, key: MediaKeysSchema.customKeybindingsListKey, values: existing)
    }
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
