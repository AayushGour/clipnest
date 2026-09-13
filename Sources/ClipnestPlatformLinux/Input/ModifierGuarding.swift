import Foundation

/// Neutralizes interfering out-of-band modifier state immediately before
/// `UInputEventSynthesizer.post` asserts a chord's own modifier keys —
/// the seam `LinuxEventSynthesizerFactory` picks a conformance for,
/// per-session-type (T-MODWAIT-WAYLAND1).
///
/// Two conformances exist because the ONLY trustworthy way to do this
/// differs by session type (see `ModifierMaskReading`'s Wayland-gap doc
/// comment for the underlying read problem):
/// - `WaitForReleaseModifierGuard` (X11 sessions): `XQueryPointer`
///   correctly reflects physical modifier state there, so this simply
///   polls the existing `ModifierReleaseWaiter` until it reports
///   released, exactly as every backend did before this type existed.
/// - `ForceReleaseModifierGuard` (Wayland / no reliable reader): posts a
///   synthetic key-up for every tracked modifier keycode through the
///   SAME uinput device the chord is about to use, unconditionally,
///   rather than trusting a read that is measured to lie (`XQueryPointer`
///   reports an empty mask while Shift/Super are physically held, 8/8
///   probe samples, whenever a native-Wayland window has focus).
///
/// **Before trusting `ForceReleaseModifierGuard`, read its own doc comment
/// first: it does NOT fix the cross-device modifier merge it was built for
/// (T-CROSSDEVICE-MODIFIER1, measured 2026-09-14) — Mutter tracks modifier
/// state PER ORIGINATING DEVICE, so a key-up posted from Clipnest's own
/// uinput device cannot clear a modifier the user's physical keyboard is
/// still asserting (15/15 still merged in a Clipnest-free control). It
/// remains wired only because it is harmless, not because it works. The
/// real, kept win from the commit that introduced this seam is
/// `LinuxEventSynthesizerFactory` switching from display-reachability to
/// `SessionType` — see `ModifierMaskReading`'s doc comment — which stopped
/// a wrong X11 reading from being silently trusted on Wayland, independent
/// of whether either `ModifierGuarding` conformance actually clears the
/// merge.**
public protocol ModifierGuarding: Sendable {
  /// - Returns: `true` once it is safe to assert the chord's own
  ///   modifiers; `false` if the caller must abandon the post rather than
  ///   risk merging with a modifier still asserted (mirrors
  ///   `ModifierReleaseWaiter.waitForRelease()`'s `.timedOut` contract).
  func clearInterferingModifiers() -> Bool
}

/// The X11-only strategy — see `ModifierGuarding`'s doc comment. A thin
/// wrapper so `UInputEventSynthesizer` depends on one seam
/// (`ModifierGuarding`) regardless of which session type built it.
public struct WaitForReleaseModifierGuard: ModifierGuarding {
  private let waiter: ModifierReleaseWaiter

  public init(waiter: ModifierReleaseWaiter) {
    self.waiter = waiter
  }

  public func clearInterferingModifiers() -> Bool {
    waiter.waitForRelease() == .released
  }
}

/// The Wayland strategy — see `ModifierGuarding`'s doc comment.
///
/// **PROVEN INEFFECTIVE — DO NOT TRUST THIS TO FIX THE MERGE
/// (T-CROSSDEVICE-MODIFIER1, measured 2026-09-14).** Mutter tracks modifier
/// state PER ORIGINATING DEVICE, so a key-up posted from Clipnest's own
/// uinput device cannot clear a modifier the user's physical keyboard is
/// still asserting. Measured Clipnest-free with two independent virtual
/// keyboards and a GTK4 key-event logger reading `Gdk.ModifierType`
/// directly:
///
///   positive control (B alone, Ctrl+C)                8/8 clean
///   baseline, A holds Shift                           8/8 merged
///   THIS STRATEGY, A holds Shift, B releases it      15/15 STILL MERGED
///   baseline, A holds Super                           8/8 merged
///   THIS STRATEGY, Super                              8/8 STILL MERGED
///   phantom release (nobody holding)                  6/6 clean, zero events emitted
///
/// The raw stream shows it directly: immediately after this guard's key-up for Shift,
/// the very next event — this device's own Ctrl press — already reports
/// `state=["SHIFT_MASK"]`. A before/after run of the full production binary against
/// its own parent commit confirmed the user-visible failure rate does not move on 7 of
/// 8 conditions, with overlapping confidence intervals on the 8th (see the board's
/// T-MODWAIT-WAYLAND1 REJECT entry).
///
/// It is retained only because it is harmless (releasing an unpressed key is a no-op
/// in evdev) and because the `ModifierGuarding` seam it fills is the right shape for a
/// strategy that CAN work — **not because it currently works.** The only remaining
/// candidate is the GNOME Shell extension's Clutter seat state — the compositor is the
/// one party that knows the true aggregate modifier state — which would make correct
/// paste depend on a component this project documents as optional. That is a product
/// decision, tracked on the board, not an implementation choice to be made here.
///
/// Mirrors the Windows analog other text-injection tools already ship for
/// the identical problem (`ReleaseModifiers`/`RestoreModifiers` in e.g.
/// OpenWhispr's `windows-fast-paste.c`, confirmed against that project's
/// actual source, not its docs: `GetAsyncKeyState` finds which modifiers
/// are truly held, `SendInput` releases exactly those, then restores them
/// after the paste) — with one deliberate, forced difference: this type
/// does NOT restore afterward. Windows can restore safely because it
/// first CONFIRMS which keys it took down via a real physical-state read;
/// the entire premise on Wayland is that no such read exists here (that
/// is the bug this type exists to route around), so a blind restore
/// risks asserting a modifier the user was never actually holding — e.g.
/// the direct-CLI-trigger path (`clipnest --expand-snippet`, no hotkey),
/// measured at 0/6 failures precisely because it holds nothing — and
/// leaving it stuck down until something else happens to clear it. A
/// release event for a key that was never down is a documented no-op in
/// evdev/XKB's key-state model, so skipping restore is safe in that case
/// by construction; the cost lands only on the case where a modifier WAS
/// genuinely held: a brief window (bounded by how quickly the user
/// releases the physical key afterward, since their own release event
/// then reaches the SAME shared state as a harmless redundant release)
/// where a different modifier-dependent action could misfire — moot for
/// the merge itself, which the measurements above show this guard does
/// not prevent either way.
public struct ForceReleaseModifierGuard: ModifierGuarding {
  private let device: any KeyEventPosting

  public init(device: any KeyEventPosting) {
    self.device = device
  }

  public func clearInterferingModifiers() -> Bool {
    for code in LinuxEventCode.allModifierKeycodes {
      guard device.postKeyEvent(code: code, isPress: false) else { return false }
    }
    return true
  }
}
