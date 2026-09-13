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
  /// This distinction exists because of T-HOTKEYGAP1/T-HOTKEYFLOOR-GAP1:
  /// gnome-settings-daemon's media-keys plugin only calls the Shell's
  /// `org.gnome.Shell.GrabAccelerators` (confirmed live via `dbus-monitor`
  /// on the real session bus — see `install`'s own doc comment) in reaction
  /// to a genuine GSettings **value change** on the per-binding `binding`
  /// key; a value-identical re-write emits no such change and gsd makes NO
  /// grab attempt at all — it does not "already hold a stale grab", it
  /// simply never tries again. `bindingChanged` here is Swift's own
  /// diagnostic view of whether ITS last-written value differed — kept for
  /// the log, but as of the T-HOTKEYFLOOR-GAP1 fix it no longer gates
  /// whether a grab is attempted (see `install`'s "always bounce" doc
  /// comment): a caller must not read `bindingChanged=false` here as "gsd's
  /// grab is therefore fine", which is exactly the wrong inference that
  /// let this bug ship (coding-standards.md's unconfirmed-vs-confirmed
  /// rule).
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

    // T-HOTKEYFLOOR-GAP1: see `bindingWriteSequence(for:)`'s doc comment for
    // the root cause this forced two-step write fixes, and why a single
    // value-identical write is not safe to keep as the fast path.
    for value in bindingWriteSequence(for: binding) {
      setString(perBinding, key: MediaKeysSchema.bindingKey, value: value)
    }

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

  /// The exact sequence of values `install` writes to the `binding` key, in
  /// order. Extracted as a small pure decision — the same "pure logic
  /// separated from the real GSettings I/O" shape
  /// `LinuxAppLifecycle.resolvedAccelerator(storedValue:defaultValue:)`
  /// already uses for this same subsystem — so the bounce sequence itself
  /// is unit-testable without a real GSettings daemon (`install`'s own
  /// GIO/C calls remain manual-verify only, per this file's top doc
  /// comment).
  ///
  /// **T-HOTKEYFLOOR-GAP1 root cause**, measured live with `dbus-monitor
  /// --session` against a real `gnome-shell`/`gsd-media-keys` (not inferred
  /// from source, and not reproducible from a wait-longer retry — see
  /// below): gnome-settings-daemon's media-keys plugin calls
  /// `org.gnome.Shell.GrabAccelerators` to (re-)acquire this key's
  /// accelerator ONLY in reaction to a genuine GSettings value change on
  /// `binding`. A same-value rewrite — exactly what `install` was doing on
  /// every steady-state call, since the floor is (re)installed on EVERY
  /// hotkey-backend reconcile
  /// (`LinuxAppLifecycle.resolveAndApplyHotkeyBackend`'s doc comment), not
  /// just once — produced ZERO `GrabAccelerators` calls, confirmed with a
  /// controlled `gsettings set` of the identical value while capturing the
  /// session bus. A failure-rate-vs-delay sweep across 0.0-5.0s of
  /// post-extension-disable delay (12 trials/bucket, 72 total, real
  /// `<Super><Shift>v` accelerator and a synthetic control accelerator)
  /// measured 0/72 successes at EVERY delay once the floor's Mutter grab
  /// had never been validly acquired — i.e. this is not a narrow timing
  /// race that a longer wait closes, it is a permanent gap: gsd does not
  /// retry a grab attempt it was never asked to retry, no matter how long
  /// you wait. The grab can fail to ever be acquired in the first place,
  /// too: if the Shell extension is already active and holding this exact
  /// accelerator via its own `Main.wm.addKeybinding`
  /// (`extension/src/core/keybindings.js`) at the moment gsd's one genuine
  /// attempt fires, that attempt loses the race — confirmed by the
  /// `GrabAccelerators` D-Bus method's own return value: `0` (Shell's
  /// documented failure sentinel) when contended, a real nonzero action id
  /// (e.g. `766`) when uncontested.
  ///
  /// **The fix**, also confirmed live the same way: force a genuine value
  /// transition on every call, regardless of whether `binding` matches what
  /// was last written, by writing the schema's own "no binding" value
  /// (`""` — the same convention GNOME Settings' own Keyboard panel uses to
  /// clear a shortcut, not a sentinel invented here) immediately before the
  /// real value. Re-running the identical disable-then-press sequence with
  /// this two-step write in place, at zero delay, turned a measured 0/12
  /// into every press firing on the very next attempt, with
  /// `GrabAccelerators` observed returning a nonzero id in place of `0`.
  ///
  /// **Rejected: gating the bounce on whether the value actually changed**
  /// (comparing against `install`'s own `previousBinding`). That flag is
  /// precisely what this bug shows cannot be trusted to mean "gsd's grab is
  /// already fine" — using it to skip the second write would silently
  /// reintroduce this exact gap for every steady-state reconcile, which is
  /// the common case this floor exists to cover, not a rare one. The extra
  /// write costs one harmless additional D-Bus round trip (tens of
  /// milliseconds, measured), off any user-facing gesture — `install` only
  /// ever runs from a hotkey-backend reconcile or an explicit rebind, never
  /// from the hotkey press itself.
  ///
  /// Returns `[binding]` unchanged when `binding` is already empty — there
  /// is no non-empty "no binding" value to bounce through, and the schema's
  /// own default is already `""`.
  static func bindingWriteSequence(for binding: String) -> [String] {
    binding.isEmpty ? [binding] : ["", binding]
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
