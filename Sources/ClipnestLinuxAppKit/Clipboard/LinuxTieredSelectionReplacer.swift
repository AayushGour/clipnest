import ClipnestCore
import Foundation

/// The single `SelectionReplacing` `LinuxAppEnvironment` hands
/// `SnippetExpander` as its `clipboardReplacer` (T-IBUS-REPLACER, D-IBUS-1):
/// tries the IBus commit tier first, falls through to the existing
/// clipboard copy/paste tier exactly as `LinuxClipboardSelectionReplacer
/// .writeText(_:)`'s own try-privileged-then-fall-back shape does, one
/// level up. `SnippetExpander` itself stays untouched — it holds exactly
/// ONE `clipboardReplacer` and has no idea this composition exists; the
/// IBus tier is entirely a Linux-side implementation detail (D-IBUS-1's
/// own "rejected: threading a third tier through SnippetExpander" call).
///
/// **Fall-through table (D-IBUS-1):**
/// - IBus -> no receptive widget / policy-excluded / client unavailable
///   (`.noSelection` from `LinuxIBusSelectionReplacer`) -> fall through to
///   the clipboard tier, exactly as `SnippetExpander` already falls
///   AT-SPI -> clipboard.
/// - IBus -> `.committedUnconfirmed` / `.replaced` / `.noMatch` ->
///   TERMINAL, returned as-is. **Never** also try the clipboard tier:
///   retrying after a real IBus commit reached a live recipient risks a
///   genuine DOUBLE INSERT, strictly worse than the bug this whole
///   feature exists to fix.
///
/// **Degradation (no `ibus-daemon`, unresolvable address, or connect
/// failure):** `LinuxAppEnvironment` never constructs a real
/// `LinuxIBusSelectionReplacer` in that case — it passes a null
/// object that always returns `.noSelection` with zero I/O, the same
/// graceful-nil convention `LinuxAppEnvironment
/// .makeSelectedTextAccessing()` already uses for AT-SPI. This composer
/// has no knowledge of that distinction; it always tries `ibusReplacer`
/// first and falls through on a non-terminal result, whether that tier is
/// real or a permanent no-op.
@MainActor
public final class LinuxTieredSelectionReplacer: SelectionReplacing {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "LinuxTieredSelectionReplacer")

  private let ibusReplacer: any SelectionReplacing
  private let clipboardReplacer: any SelectionReplacing

  public init(ibusReplacer: any SelectionReplacing, clipboardReplacer: any SelectionReplacing) {
    self.ibusReplacer = ibusReplacer
    self.clipboardReplacer = clipboardReplacer
  }

  public func replaceSelection(bodyForSelection: (String) async -> String?) async
    -> SelectionReplaceResult
  {
    let ibusResult = await ibusReplacer.replaceSelection(bodyForSelection: bodyForSelection)
    Self.logger.notice("tier=ibus: outcome=\(String(describing: ibusResult))")
    if Self.isTerminal(ibusResult) {
      return ibusResult
    }
    Self.logger.notice("tier=ibus: falling through to clipboard tier")
    return await clipboardReplacer.replaceSelection(bodyForSelection: bodyForSelection)
  }

  /// D-IBUS-1's fall-through table, in code: `.committedUnconfirmed` and
  /// `.noMatch` are IBus's own real, definitive answers and must never be
  /// retried via the clipboard tier. `.replaced` is included defensively
  /// — `LinuxIBusSelectionReplacer` never actually produces it (IBus can
  /// never CONFIRM a commit; see `SelectionReplaceResult
  /// .committedUnconfirmed`'s doc comment) — but treating a hypothetical
  /// future `.replaced` as anything OTHER than terminal would itself be
  /// the bug. Every other case means "this tier found nothing definitive,
  /// safe to retry."
  private static func isTerminal(_ result: SelectionReplaceResult) -> Bool {
    switch result {
    case .committedUnconfirmed, .replaced, .noMatch:
      return true
    case .noSelection, .writeUnconfirmed, .copyUnconfirmed, .declinedTerminalTarget:
      return false
    }
  }
}
