// ItemPreviewController.swift
//
// Task 12 (item preview): presents `ItemPreview` (Task 11) beside the picker
// WITHOUT taking key focus — the picker is a non-activating `NSPanel`
// (`PickerPanel`) and the whole keyboard flow depends on its search field
// keeping first-responder status (project-context.md decision D11, a prior
// focus-steal bug). A regular `NSPopover`/SwiftUI `.popover` risks becoming
// key when shown from a non-activating panel, so this uses the same
// technique `PickerPanel` itself uses to avoid activating the app: a
// borderless, `.nonactivatingPanel`-style-masked child `NSPanel`, shown with
// `orderFrontRegardless()` and NEVER `makeKey()`/`makeKeyAndOrderFront(_:)`/
// `NSApp.activate(...)`. `AppEnvironment` owns the single instance of this
// controller and drives `update(...)` from
// `PickerView`'s `.onChange(of: viewModel.previewTargetID)`.

import AppKit
import ClipnestCore
import SwiftUI

@MainActor
final class ItemPreviewController {
  private var panel: NSPanel?

  /// Shows `item`'s preview beside `anchorRect` (in screen coordinates), or
  /// hides the preview if `item` (or `anchorRect`) is `nil`. Never becomes
  /// key — the panel's `styleMask` includes `.nonactivatingPanel` and this
  /// only ever calls `orderFrontRegardless()`, so showing/updating the
  /// preview can never steal first-responder status from the picker's
  /// search field.
  func update(
    item: ClipItem?,
    blobStore: BlobStore,
    besideAnchor anchorRect: NSRect?,
    onPreviewHover: @escaping (Bool) -> Void
  ) {
    guard let item, let anchorRect else {
      hide()
      return
    }
    let panel = panel ?? makePanel()
    self.panel = panel
    // Images render up to 40% of the screen width — BUT never wider than the
    // space actually available beside the picker, so the popover can sit next
    // to the picker without overlapping it. Without this cap, a 40%-of-a-wide-
    // screen image made the panel too wide to fit beside the picker, and the
    // position clamp then shoved it back over the picker.
    let visible =
      (NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main)?
      .visibleFrame ?? anchorRect
    // Gap wide enough to clear the panel's ~20pt drop shadow, so the shadow
    // doesn't bleed onto the picker (which read as an overlap even when the
    // frames didn't touch).
    let gap: CGFloat = 24
    let sideSpace = max(visible.maxX - anchorRect.maxX - gap, anchorRect.minX - visible.minX - gap)
    // Reserve the popover's own horizontal padding + drop shadow + slack, so
    // the whole panel (image + chrome + shadow) fits the side with clear air
    // between it and the picker.
    let imageMaxWidth = max(140, min(visible.width * 0.4, sideSpace - 72))
    // `.id(item.id)` gives the hosted `ItemPreview` a per-item identity so
    // its internal image-loading `@State` (see `ItemPreview.AsyncBlobImage`)
    // resets when the previewed item changes, instead of briefly showing
    // the previous item's already-loaded image while the new one loads.
    // `onHover` reports pointer hover over the popover back to the view model
    // so it stays open (and scrollable) while hovered.
    let hostingController = NSHostingController(
      rootView: ItemPreview(
        item: item, blobStore: blobStore, imageMaxWidth: imageMaxWidth, onHover: onPreviewHover
      ).id(item.id))
    panel.contentViewController = hostingController
    let fittingSize = hostingController.view.fittingSize
    panel.setContentSize(
      NSSize(
        width: max(fittingSize.width, 200),
        height: max(fittingSize.height, 100)))
    // Vertically center the popover on the pointer (which is over the hovered
    // row), so it appears beside that row rather than at the picker's top.
    positionPanel(panel, besideAnchor: anchorRect, atVerticalCenter: NSEvent.mouseLocation.y)
    // Never makeKey/makeKeyAndOrderFront — must not steal the search
    // field's first-responder status. See this file's top doc comment.
    panel.orderFrontRegardless()
  }

  /// Hides the preview panel, if shown. Safe to call even if already
  /// hidden/never shown.
  func hide() {
    panel?.orderOut(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered, defer: true)
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.hasShadow = true
    panel.backgroundColor = .clear
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return panel
  }

  /// Places `panel` beside `anchorRect` (the picker), vertically centered on
  /// `cursorY` (the pointer's screen Y, i.e. the hovered row). Chooses the side
  /// where the panel FULLY fits so it never overlaps the picker — right if it
  /// fits, else left; only if neither fits (shouldn't happen — the image width
  /// is capped to the roomier side in `update`) does it sit flush against the
  /// roomier screen edge. Vertically clamped on-screen.
  private func positionPanel(
    _ panel: NSPanel, besideAnchor anchorRect: NSRect, atVerticalCenter cursorY: CGFloat
  ) {
    // Gap wide enough to clear the panel's ~20pt drop shadow, so the shadow
    // doesn't bleed onto the picker (which read as an overlap even when the
    // frames didn't touch).
    let gap: CGFloat = 24
    let width = panel.frame.width
    let height = panel.frame.height
    let visible =
      (NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main)?
      .visibleFrame ?? anchorRect
    let spaceRight = visible.maxX - anchorRect.maxX - gap
    let spaceLeft = anchorRect.minX - visible.minX - gap

    let originX: CGFloat
    if spaceRight >= width {
      originX = anchorRect.maxX + gap
    } else if spaceLeft >= width {
      originX = anchorRect.minX - width - gap
    } else if spaceRight >= spaceLeft {
      originX = visible.maxX - width
    } else {
      originX = visible.minX
    }

    var origin = NSPoint(x: originX, y: cursorY - height / 2)
    origin.y = min(max(origin.y, visible.minY), visible.maxY - height)
    panel.setFrameOrigin(origin)
  }
}
