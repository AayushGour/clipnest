// GlobalHotkeyAccelerator.swift
//
// T-OPT2 (Linux port, GTK4 view layer): reads/writes the
// `app.clipnest.Clipnest.Keybindings` GSettings schema's `toggle-picker`/
// `expand-snippet` keys (type `as`) directly — the ONE schema both this app
// and the GNOME Shell extension read (`extension/src/core/keybindings.js`),
// so rebinding from Settings is a single `g_settings_set_strv()` with no
// IPC to the extension at all: `Main.wm.addKeybinding()` is already
// watching these SAME keys via its own `Gio.Settings` `'changed'` signal
// and re-grabs immediately. See `packaging/linux/schemas/app.clipnest.
// Clipnest.Keybindings.gschema.xml`'s own header comment for the full
// contract.
//
// T-HOTKEY1: generalized from a toggle-picker-only type to a `Key`-
// parameterized one — Settings > Shortcuts now shows and rebinds BOTH
// global hotkeys, and this is the one place that reads/writes either. Both
// keys share the exact same schema/GSettings-I/O shape (an `as` array,
// "usually zero or one entry" convention, same missing-schema failure
// mode) — a `Key` parameter avoids two near-identical copies of
// `current`/`write`/the C-string marshalling, per coding-standards.md's DRY
// rule.
//
// Schema ID + key names are DELIBERATELY duplicated from
// `ShellExtensionKeybindingSchema` (`ClipnestLinuxAppKit/DBus/
// ShellHelperNames.swift`) rather than shared — `ClipnestGTK` does not (and
// per `Package.swift`'s dependency graph, must not: `ClipnestLinuxAppKit`
// depends on `ClipnestGTK`, never the reverse) import that module. Matches
// this codebase's own precedent for exactly this situation (see
// `Support/LinuxShortcutDescriptions.swift`'s "separate, deliberately
// duplicated" doc comment for the identical cross-module-boundary reason).
// If the two ever need to change, they must change together; a reasonable
// follow-up (not done here, out of this task's owned-files scope: neither
// file is one of them) would hoist both strings into `ClipnestCore`, which
// both modules already depend on, as a single shared source of truth.
import CGtk4

#if canImport(Glibc)
  import Glibc
#endif

public enum GlobalHotkeyAccelerator {
  static let schemaID = "app.clipnest.Clipnest.Keybindings"

  /// Which of the two global hotkeys in the shared schema to read/write.
  /// Mirrors `ShellExtensionKeybindingSchema`'s `togglePickerKey`/
  /// `expandSnippetKey` constants exactly (see this file's top doc comment
  /// on why they're duplicated here rather than imported).
  public enum Key: Sendable {
    case togglePicker
    case expandSnippet

    var settingsKeyName: String {
      switch self {
      case .togglePicker: return "toggle-picker"
      case .expandSnippet: return "expand-snippet"
      }
    }
  }

  /// Reads `key`'s current accelerator, or `nil` if unbound (an empty list
  /// — the schema's own documented "unbound" convention) or if the schema
  /// isn't installed at all (see `schemaIsInstalled()`'s doc comment for
  /// why that check runs first, always).
  public static func current(_ key: Key) -> String? {
    guard schemaIsInstalled() else { return nil }
    guard let settings = schemaID.withCString({ g_settings_new($0) }) else { return nil }
    guard
      let cArray = key.settingsKeyName.withCString({ g_settings_get_strv(settings, $0) })
    else {
      return nil
    }
    defer { g_strfreev(cArray) }
    guard let first = cArray[0] else { return nil }
    return String(cString: first)
  }

  /// Writes `accelerator` as `key`'s SOLE binding (replacing whatever was
  /// there — this schema's convention is "usually zero or one entry," see
  /// the schema XML's own header comment). Returns `false` (no write
  /// attempted) for an empty string or a missing schema — every caller is
  /// expected to have already run `GlobalHotkeyAcceleratorValidation
  /// .validate(keyval:state:)` on the captured chord before calling this, so
  /// an empty string reaching here would be a caller bug, not a normal path.
  @discardableResult
  public static func write(_ accelerator: String, for key: Key) -> Bool {
    guard !accelerator.isEmpty else { return false }
    guard schemaIsInstalled() else { return false }
    guard let settings = schemaID.withCString({ g_settings_new($0) }) else { return false }

    #if canImport(Glibc)
      var cStrings: [UnsafeMutablePointer<CChar>?] = [Glibc.strdup(accelerator)]
      cStrings.append(nil)
      defer {
        for pointer in cStrings where pointer != nil { free(pointer) }
      }
      return cStrings.withUnsafeMutableBufferPointer { buffer -> Bool in
        buffer.baseAddress!.withMemoryRebound(
          to: UnsafePointer<CChar>?.self, capacity: buffer.count
        ) { rebound in
          key.settingsKeyName.withCString { g_settings_set_strv(settings, $0, rebound) != 0 }
        }
      }
    #else
      return false
    #endif
  }

  /// Whether the shared `app.clipnest.Clipnest.Keybindings` schema is
  /// actually installed on this machine. NOT optional — `g_settings_new`/
  /// `g_settings_new_with_path` treat a missing schema as a PROGRAMMER
  /// ERROR and ABORT THE PROCESS (`GLib-GIO-ERROR ** Settings schema '...'
  /// is not installed`); they never return `nil`, so a `guard let` around
  /// the constructor alone provides zero protection. This schema ships
  /// with the `clipnest` package itself (`debian/clipnest.install`,
  /// compiled by `debian/clipnest.postinst`), so it is always present on a
  /// real installed system — this guard exists for the dev-loop case (a
  /// `swift run`/`swift test` binary with no `.deb` ever installed, no
  /// schema ever compiled into `/usr/share/glib-2.0/schemas`), matching
  /// `GSettingsCustomKeybinding.schemaIsInstalled`'s identical, independently
  /// duplicated guard (`ClipnestLinuxAppKit/Hotkeys/`) for the same D68
  /// lesson (see `project-context.md`).
  static func schemaIsInstalled() -> Bool {
    guard let source = g_settings_schema_source_get_default() else { return false }
    guard let schema = schemaID.withCString({ g_settings_schema_source_lookup(source, $0, 1) })
    else { return false }
    g_settings_schema_unref(schema)
    return true
  }
}
