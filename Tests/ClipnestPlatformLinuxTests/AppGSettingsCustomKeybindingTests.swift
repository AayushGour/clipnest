// AppGSettingsCustomKeybindingTests.swift
//
// T-HOTKEYFLOOR-GAP1: `GSettingsCustomKeybinding.install` itself remains
// manual-verify only (real GIO/GSettings calls, no daemon in the CI
// container — see that type's own top doc comment). What IS unit-testable,
// and is exactly the part that was wrong, is the pure decision of WHAT
// sequence of values gets written to the `binding` key —
// `bindingWriteSequence(for:)`, extracted for this reason (mirrors
// `LinuxAppLifecycle.resolvedAccelerator`'s existing precedent for the same
// subsystem). These tests pin the fix: a real accelerator must ALWAYS
// bounce through the schema's own empty "no binding" value first, on every
// call, regardless of whether the caller's value happens to match what was
// last installed — the single-write, "skip when unchanged" behavior this
// replaces is what left gnome-settings-daemon never re-grabbing the
// accelerator after the Shell extension released it (measured live: 0/72
// hotkey presses fired across a 0.0-5.0s post-disable delay sweep under the
// old single-write behavior; see `bindingWriteSequence`'s doc comment for
// the full live evidence).
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("GSettingsCustomKeybinding.bindingWriteSequence")
struct AppGSettingsCustomKeybindingTests {
  @Test("a real accelerator always bounces through empty first, then the real value")
  func realAcceleratorBounces() {
    #expect(
      GSettingsCustomKeybinding.bindingWriteSequence(for: "<Super><Shift>v")
        == ["", "<Super><Shift>v"])
  }

  @Test(
    "bounces even when the caller's value is IDENTICAL to what a naive diff would call unchanged"
  )
  func bouncesEvenWhenCallerBelievesNothingChanged() {
    // This is the actual bug: `install`'s own `previousBinding != binding`
    // comparison (still logged as `bindingChanged`, for diagnostics) must
    // NOT gate this sequence — gsd's regrab depends on a value CHANGE
    // happening on the wire, not on whether Swift's cached value differs.
    // Calling this twice in a row with the same accelerator must produce
    // the identical bounce sequence both times.
    let first = GSettingsCustomKeybinding.bindingWriteSequence(for: "<Super><Shift>e")
    let second = GSettingsCustomKeybinding.bindingWriteSequence(for: "<Super><Shift>e")
    #expect(first == ["", "<Super><Shift>e"])
    #expect(second == ["", "<Super><Shift>e"])
  }

  @Test("an already-empty binding is left as a single write — nothing to bounce through")
  func emptyBindingIsNotBounced() {
    #expect(GSettingsCustomKeybinding.bindingWriteSequence(for: "") == [""])
  }

  @Test("the bounce value is the schema's own empty string, never a made-up sentinel")
  func bounceValueIsPlainEmptyString() {
    let sequence = GSettingsCustomKeybinding.bindingWriteSequence(for: "<Super><Shift>v")
    #expect(sequence.first == "")
  }
}
