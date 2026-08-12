// WindowPlacement.swift
//
// Small shared, pure geometry helpers for positioning Clipnest's AppKit
// windows/panels on screen. Kept AppKit-free at the math level (CGRect/
// CGPoint/CGSize only) so the placement logic itself has no dependency on
// a live NSWindow/NSScreen and stays easy to reason about — the AppKit
// call sites (`PickerPanel`, `SnippetEditorWindow`) supply `.frame`/
// `.screen.visibleFrame` and get a clamped/placed origin back.
//
// `clampedOrigin` is extracted here per coding-standards.md's DRY
// non-negotiable: `PickerPanel` (position at the cursor) already had its
// own private clamp-into-visible-bounds formula, and the snippet-editor
// placement fix needs the exact same clamp as its final step — so the
// clamp itself now lives in exactly one place instead of two.
//
// `pairLayout` (round 2 of the snippet-editor placement fix): the first
// version tried "beside the picker at its current position, else
// below/above" — but "below/above" always reused the picker's existing
// left edge, which reads as the same overlapping stack the fix was meant
// to prevent whenever right/left both failed to fit. Real requirement:
// the editor must ALWAYS end up beside the picker with a distinct left
// edge and (whenever the two windows can possibly fit side by side on the
// screen) zero overlap — moving the *picker* horizontally, not falling
// back to stacking, is how that's guaranteed.

import CoreGraphics

enum WindowPlacement {
  /// Clamps `origin` (for a window of `size`) so the resulting frame is
  /// fully contained within `bounds` (typically an `NSScreen`'s
  /// `visibleFrame`) — never partially off-screen, even if the unclamped
  /// origin would put it there.
  static func clampedOrigin(_ origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
    let maxX = max(bounds.maxX - size.width, bounds.minX)
    let maxY = max(bounds.maxY - size.height, bounds.minY)
    return CGPoint(
      x: min(max(origin.x, bounds.minX), maxX),
      y: min(max(origin.y, bounds.minY), maxY)
    )
  }

  /// Computes a side-by-side layout for the picker + editor "pair":
  /// picker on the left, editor to its right with `gap` between them,
  /// editor top-aligned to the picker's top edge — moving the *picker's*
  /// origin (never the editor's size, never the picker's size) as needed
  /// so the pair fits fully inside `screenVisibleFrame`. Returns both
  /// windows' new origins; the caller sets both frames.
  ///
  /// - If `pickerFrame.width + gap + editorSize.width` fits within
  ///   `screenVisibleFrame`'s width, the pair is placed with **zero
  ///   overlap**: the picker is shifted left only as far as needed (never
  ///   right, never resized) so the editor has room to its right, fully
  ///   on screen; if the picker's current position already leaves enough
  ///   room, it isn't moved at all.
  /// - If the pair genuinely can't fit the screen's visible width at both
  ///   windows' full sizes (a very narrow display), the picker is clamped
  ///   on screen as-is and the editor is pushed as far right as it'll go
  ///   (flush against the screen's right edge) — this maximizes the
  ///   non-overlapping region, and since the editor's width is virtually
  ///   always smaller than the screen's, its left edge still ends up
  ///   distinct from the picker's; a last-resort 1pt nudge guarantees
  ///   distinct left edges even in the pathological case where it
  ///   wouldn't be (editor width >= screen width).
  /// - Both origins are always run through `clampedOrigin` as a final
  ///   step, so neither window can end up partially off-screen.
  ///
  /// AppKit screen coordinates: origin is bottom-left, Y increases
  /// upward — so "top-aligned" means the editor's `maxY` matches the
  /// picker's `maxY`.
  static func pairLayout(
    pickerFrame: CGRect,
    editorSize: CGSize,
    screenVisibleFrame: CGRect,
    gap: CGFloat
  ) -> (pickerOrigin: CGPoint, editorOrigin: CGPoint) {
    let pairWidth = pickerFrame.width + gap + editorSize.width

    var pickerX = pickerFrame.minX
    var editorX: CGFloat
    if pairWidth <= screenVisibleFrame.width {
      // Fits — shift the picker left only as far as needed for the editor
      // to have room to its right, fully on screen; never shift right.
      let maxPickerX = screenVisibleFrame.maxX - gap - editorSize.width - pickerFrame.width
      pickerX = min(pickerX, maxPickerX)
      pickerX = max(pickerX, screenVisibleFrame.minX)
      editorX = pickerX + pickerFrame.width + gap
    } else {
      // Doesn't fit at full size — clamp the picker where it already is,
      // push the editor flush to the screen's right edge (maximizes the
      // non-overlapping gap), and guarantee a distinct left edge even in
      // the pathological case that still isn't enough separation.
      pickerX = min(
        max(pickerX, screenVisibleFrame.minX), screenVisibleFrame.maxX - pickerFrame.width)
      editorX = screenVisibleFrame.maxX - editorSize.width
      if editorX <= pickerX {
        editorX = pickerX + 1
      }
    }

    let pickerOrigin = clampedOrigin(
      CGPoint(x: pickerX, y: pickerFrame.minY), size: pickerFrame.size, in: screenVisibleFrame)
    let editorTopAlignedY = pickerOrigin.y + pickerFrame.height - editorSize.height
    let editorOrigin = clampedOrigin(
      CGPoint(x: editorX, y: editorTopAlignedY), size: editorSize, in: screenVisibleFrame)

    return (pickerOrigin, editorOrigin)
  }
}
