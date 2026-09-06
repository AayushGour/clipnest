import Foundation

#if os(macOS)
  import AppKit
#endif

/// Backs the global snippet-expansion hotkey (⌥⌘E): reads the current
/// selection, looks it up as a snippet keyword, and replaces the selection
/// with the snippet body on a match. No match / no selection → a system beep.
///
/// Works in ANY application via a two-strategy approach:
///  1. **Accessibility first** (`SelectedTextAccessing`): reads and replaces
///     the selection directly, WITHOUT touching the clipboard. Used wherever
///     it works — native / most Cocoa text (TextEdit, Notes, Safari fields).
///  2. **Clipboard fallback** (`SelectionReplacing`): when AX can't read the
///     selection (Electron/Chrome/Java apps don't expose it), synthesize
///     copy/paste — which every app supports — snapshotting and RESTORING the
///     clipboard around it so it ends up unchanged. This is the universal,
///     foolproof path; the clipboard is only borrowed when AX can't do it.
///
/// The concrete implementations (`AXSelectedTextAccessor`,
/// `ClipboardSelectionReplacer`) live in the app target; both are injected so
/// `ClipnestCore` never references app-only types, mirroring `Paster`'s
/// protocol-in-Core / concrete-impl-in-app split.
///
/// `@MainActor`: `expand()` drives the Accessibility API, `NSPasteboard`, key
/// synthesis, and `NSSound.beep()` — all main-thread work — so the whole class
/// is main-actor-isolated (callers get a plain, non-`unsafe` stored property).
@MainActor
public final class SnippetExpander {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "SnippetExpander")

  private let snippetStore: any SnippetStore
  private let selectedText: any SelectedTextAccessing
  private let clipboardReplacer: any SelectionReplacing
  private let beep: () -> Void

  public init(
    snippetStore: any SnippetStore,
    selectedText: any SelectedTextAccessing,
    clipboardReplacer: any SelectionReplacing,
    beep: @escaping () -> Void = PlatformDefaults.beep
  ) {
    self.snippetStore = snippetStore
    self.selectedText = selectedText
    self.clipboardReplacer = clipboardReplacer
    self.beep = beep
  }

  /// The snippet body for a given selection, or `nil` if it matches nothing —
  /// shared by both strategies. Trimmed/case-folded matching lives in
  /// `SnippetStore.findByKeyword`.
  private func body(for selection: String) async -> String? {
    do {
      return try await snippetStore.findByKeyword(selection)?.body
    } catch {
      Self.logger.error("findByKeyword failed: \(String(describing: error))")
      return nil
    }
  }

  /// Reads the current selection and replaces it with the matched snippet
  /// body; beeps if nothing was selected or nothing matched.
  public func expand() async {
    // 1) Accessibility path — no clipboard side effect where it works.
    if let selection = selectedText.readSelectedText(),
      !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      guard let snippetBody = await body(for: selection) else {
        // AX read succeeded, so the keyword is real — a clipboard re-read
        // would yield the same non-match. Beep and stop.
        beep()
        return
      }
      if selectedText.replaceSelectedText(with: snippetBody) {
        return
      }
      // AX read worked but the write was refused — fall through to the
      // clipboard path, which pastes the body via a synthesized ⌘V.
    }

    // 2) Clipboard fallback — works in ANY app (Electron/Chrome/etc.), and
    // restores the clipboard afterward. Reached when AX couldn't read the
    // selection at all, or read it but couldn't write.
    let result = await clipboardReplacer.replaceSelection(
      bodyForSelection: { await self.body(for: $0) })
    if result != .replaced {
      beep()
    }
  }
}

#if os(macOS)
  extension PlatformDefaults {
    /// The production "nothing matched" feedback on macOS — the standard
    /// system alert sound.
    public static var beep: () -> Void { { NSSound.beep() } }
  }
#else
  extension PlatformDefaults {
    /// ASCII BEL (`\a`) — writing this byte to a terminal rings its bell
    /// (and, under the X11/Xorg default `xset b` configuration, the
    /// hardware/PC-speaker bell too on a plain X session), with no display
    /// connection and no GTK/GDK link required. Internal (not `private`),
    /// like `PrivacyFilter`'s concealed/transient raw UTI values, so
    /// `SnippetExpanderTests` can pin its exact value directly — a typo'd
    /// byte here would silently swap "audible feedback" for "print an
    /// arbitrary control character," exactly the kind of silent failure
    /// this feature's whole fix (T-BUG5) exists to prevent.
    static let terminalBellByte: UInt8 = 0x07

    /// T-BUG5 (parity-audit bug #5): previously a silent no-op — a snippet
    /// expansion that matched nothing (or had no selection) gave the user
    /// NO feedback at all on Linux, unlike macOS's audible `NSSound.beep()`
    /// above, so there was no way to tell the feature had even run.
    ///
    /// `gdk_display_beep()` would be the closest Linux equivalent, but
    /// it's unreachable from here: this file's module, `ClipnestCore`, is
    /// a plain SPM library with ZERO third-party dependencies and no
    /// GTK/display dependency at all by design (see coding-standards.md's
    /// Dependency policy and Module layout — the whole point of this
    /// module is being fully unit-testable with no UI/display). Linking
    /// `CGtk4` into it would need a `Package.swift` change (out of this
    /// task's scope, `Sources/ClipnestCore/Paste/Paster.swift`'s
    /// `PlatformDefaults.beep` only) and would break that "zero UI"
    /// contract for every other consumer of `ClipnestCore`. The terminal
    /// bell is the dependency-free fallback the task's own brief names for
    /// exactly this situation — no display, no GTK/GDK, and no extra
    /// `libcanberra` dependency either (also not on coding-standards.md's
    /// approved dependency list, and it would need its own new
    /// `systemLibrary` target to add).
    ///
    /// This is audible only when Clipnest is actually attached to a
    /// terminal (e.g. run manually or under CI) — a desktop-launched GUI
    /// session's stderr is typically not a terminal at all. Still
    /// injectable, like every other `PlatformDefaults.*` default (see
    /// `SnippetExpander.init`'s `beep` parameter): a future Linux
    /// composition-root change can override it with a real
    /// `gdk_display_beep()`-backed closure once `LinuxAppEnvironment`
    /// wires one up — out of this task's scope, since that file belongs to
    /// a different owner.
    public static var beep: () -> Void {
      { FileHandle.standardError.write(Data([terminalBellByte])) }
    }
  }
#endif
