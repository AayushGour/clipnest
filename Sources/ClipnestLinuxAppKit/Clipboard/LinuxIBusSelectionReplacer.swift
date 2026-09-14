import ClipnestCore
import ClipnestPlatformLinux
import Foundation

/// Snippet expansion's IBus commit tier (T-IBUS-REPLACER, D-IBUS-1..6):
/// drives `IBusCommitClient` (via the `IBusReplacing` seam, for
/// testability — see that protocol's own doc comment) and maps its
/// `IBusCommitOutcome` onto `ClipnestCore.SelectionReplaceResult`, the ONE
/// place that mapping happens (`IBusCommitOutcome`'s own doc comment).
///
/// Conforms to the SAME `SelectionReplacing` protocol
/// `LinuxClipboardSelectionReplacer` does — `LinuxTieredSelectionReplacer`
/// composes this tier with that one, exactly mirroring
/// `LinuxClipboardSelectionReplacer.writeText(_:)`'s own existing
/// try-privileged-then-fall-back shape, one level up (D-IBUS-1).
///
/// **Policy check runs BEFORE any IBus I/O** — same "decide before
/// touching anything" shape `LinuxClipboardSelectionReplacer`'s own
/// terminal-decline gate (T-TERMPASTE1) uses, just with the opposite
/// default (`IBusCommitPolicy.isEligible` defaults to `true`, since the
/// Electron POC found no app class needing exclusion — see that type's own
/// doc comment). A policy-excluded target never switches the global
/// engine at all.
@MainActor
public final class LinuxIBusSelectionReplacer: SelectionReplacing {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "LinuxIBusSelectionReplacer")

  private let client: any IBusReplacing
  private let frontmostAppProvider: any FrontmostAppReferenceProviding

  /// Not `public`: `client`'s type (`IBusReplacing`) is a module-internal
  /// testability seam (see that protocol's own doc comment) — only
  /// `LinuxAppEnvironment.init`, in this same module, constructs this
  /// class.
  init(client: any IBusReplacing, frontmostAppProvider: any FrontmostAppReferenceProviding) {
    self.client = client
    self.frontmostAppProvider = frontmostAppProvider
  }

  public func replaceSelection(bodyForSelection: (String) async -> String?) async
    -> SelectionReplaceResult
  {
    let frontmostRef = frontmostAppProvider.currentFrontmostAppRef()
    guard IBusCommitPolicy.isEligible(appIdentifier: frontmostRef?.bundleID) else {
      // D-IBUS-1's fall-through table: policy-excluded falls through to
      // the next tier, mapped onto `.noSelection` — the same case every
      // other "this tier has nothing definitive, try the next one" reason
      // below maps to (see `map(_:)`'s own doc comment for why they share
      // one case with distinct LOG reasons, the same convention
      // `LinuxClipboardSelectionReplacer`'s own diagnostics already use).
      Self.logger.notice(
        "outcome=noSelection reason=policyExcluded appIdentifier=\(frontmostRef?.bundleID ?? "?")"
      )
      return .noSelection
    }

    // `ClipnestCore.SelectionReplacing`'s protocol requirement (which this
    // task does not touch beyond adding `.committedUnconfirmed`) declares
    // `bodyForSelection` as a plain, non-`Sendable`, non-escaping closure —
    // `IBusReplacing.replaceSelection` needs `sending @escaping` (its real
    // implementation, `IBusCommitClient`, runs the call on a background
    // executor, off the `@MainActor` this method itself runs on: real
    // blocking `NSCondition.wait()` calls happen inside, which must never
    // block the GTK main thread). Bridging the two needs BOTH fixes at
    // once: `withoutActuallyEscaping` proves the escaping half (valid only
    // because this whole call is fully `await`ed before it returns, so the
    // escaping wrapper never outlives the scope that proves it's still
    // valid), and `OneShotBodyForSelectionBox` proves the Sendable half —
    // not just past the type-checker: `bodyForSelection` is captured and
    // called EXACTLY ONCE, always via `await`, never concurrently, the
    // same "the compiler's static proof is incomplete, not the runtime
    // safety" gap `IBusCommitClient: @unchecked Sendable`'s own doc
    // comment already accepts for this codebase's live-I/O types
    // (`PickerVisibilityBox` in `LinuxAppEnvironment.swift` is the same
    // pattern one layer up). The innermost closure literal captures ONLY
    // `box` (itself `Sendable`), so the compiler infers it `@Sendable`
    // without needing an explicit annotation.
    let outcome = await withoutActuallyEscaping(bodyForSelection) { escaping in
      let box = OneShotBodyForSelectionBox(call: escaping)
      // `@Sendable` explicit on the literal: a closure literal created
      // inside a `@MainActor` method otherwise INFERS `@MainActor`
      // isolation for itself, regardless of what it captures — this
      // overrides that inference so the closure's declared isolation (not
      // just its captures) is what `IBusReplacing.replaceSelection`'s
      // `sending` parameter needs to accept a transfer.
      let forward: @Sendable (String) async -> String? = { selection in
        await box.call(selection)
      }
      return await client.replaceSelection(bodyForSelection: forward)
    }
    let result = Self.map(outcome)
    Self.logger.notice(
      "outcome=\(String(describing: result)) ibusOutcome=\(String(describing: outcome))")
    return result
  }

  /// `IBusCommitOutcome` -> `SelectionReplaceResult`, per D-IBUS-1's
  /// fall-through table: `.unavailable`/`.noLiveRecipient`/`.noSelection`
  /// all collapse to the SAME returned `.noSelection` (fall through to the
  /// next tier is the only thing any of them means to a caller composing
  /// tiers), while `.noMatch`/`.committedUnconfirmed` stay distinct and
  /// TERMINAL — a caller must be able to tell "IBus itself found a real
  /// answer" (never retry) apart from "IBus has nothing to say this
  /// attempt" (retry), even though the intermediate reasons for the
  /// latter are only preserved in the log line above, not the return
  /// value — mirrors `LinuxClipboardSelectionReplacer`'s own established
  /// convention of many internal `reason=...` log values collapsing to
  /// one returned enum case.
  private static func map(_ outcome: IBusCommitOutcome) -> SelectionReplaceResult {
    switch outcome {
    case .unavailable, .noLiveRecipient, .noSelection:
      return .noSelection
    case .noMatch:
      return .noMatch
    case .committedUnconfirmed:
      return .committedUnconfirmed
    }
  }
}

/// A one-shot `@unchecked Sendable` wrapper around a
/// `SelectionReplacing.replaceSelection(bodyForSelection:)`-shaped
/// closure — see `LinuxIBusSelectionReplacer.replaceSelection`'s own
/// comment at its one call site for why this is safe in practice, not
/// just past the type-checker. Never mutated after `init`; `call` is
/// invoked exactly once by that one call site.
private struct OneShotBodyForSelectionBox: @unchecked Sendable {
  let call: (String) async -> String?
}
