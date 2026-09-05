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
//
// T-PF3 (P0 image-hang fix), D4: `update(...)` used to (1) build a BRAND NEW
// `NSHostingController` on every call — every hover, at the picker's ~20ms
// hover cadence (`PickerViewModel+Preview.previewShowDelay`) — and (2) call
// `hostingController.view.fittingSize`, forcing a full synchronous SwiftUI
// layout pass before the panel could be sized. Combined with D1's unbounded
// image decode, that synchronous layout pass on an `.image` preview is what
// produced the reported hang. Two fixes, below: `hostingController` is now a
// single instance reused across calls (`.rootView` reassigned, not
// recreated — `ItemPreview`'s own `.id(item.id)` still resets its internal
// `@State` per item, so reuse doesn't change behavior); and a plain `.image`
// preview (no recognized-text section) computes its content size directly
// from known/bounded quantities (`boundedImageContentSize`) instead of
// calling `fittingSize` at all. `fittingSize` is still used for text/file
// previews and for an image WITH a recognized-text section — those need
// real text layout to size correctly, same as before.

import AppKit
import ClipnestCore
import ClipnestViewModels
import SwiftUI

@MainActor
final class ItemPreviewController {
  /// Gap between the picker and the preview. Wide enough to clear the
  /// panel's ~20pt drop shadow, so the shadow doesn't bleed onto the picker
  /// (which read as an overlap even when the frames didn't touch). Shared by
  /// the width cap in `update` and the placement in `positionPanel` — they
  /// have to agree or the panel is sized for one gap and placed with another.
  private static let gap: CGFloat = 24
  /// Floor on the panel's content size — small enough to never be hit by
  /// real content, just a guard against a near-empty popover if a preview's
  /// content were ever pathologically tiny.
  private static let minPanelWidth: CGFloat = 200
  private static let minPanelHeight: CGFloat = 100

  private var panel: NSPanel?
  /// Reused across every `update(...)` call instead of rebuilding an
  /// `NSHostingController` (and its whole SwiftUI view hierarchy) on every
  /// hover — see this file's top doc comment. `AnyView`-erased because a
  /// stored property needs a concrete type, and each call's rootView is
  /// `ItemPreview(...).id(item.id)`, an opaque `some View` whose concrete
  /// type isn't nameable here.
  private var hostingController: NSHostingController<AnyView>?

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
    let gap: CGFloat = Self.gap
    // The side is decided from the picker's position alone (see
    // `WindowPlacement.previewSide`), so every item in a session gets the
    // same side — and the image is then capped to THAT side's room rather
    // than the roomier one, which is what keeps it fitting there.
    //
    // P5 (Phase 3, Linux port): `ClipnestViewModels.` fully qualifies every
    // `WindowPlacement` reference in this file — this SDK's `SwiftUI` module
    // now also declares its own public `WindowPlacement` struct, and with
    // both `ClipnestCore`/`ClipnestViewModels` and `SwiftUI` imported, the
    // bare name is genuinely ambiguous (a real build error, not a style
    // choice).
    let side = ClipnestViewModels.WindowPlacement.previewSide(
      anchorRect: anchorRect, screenVisibleFrame: visible, gap: gap)
    let sideSpace = ClipnestViewModels.WindowPlacement.previewAvailableWidth(
      on: side, anchorRect: anchorRect, screenVisibleFrame: visible, gap: gap)
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
    let hostingController =
      self.hostingController ?? NSHostingController(rootView: AnyView(EmptyView()))
    self.hostingController = hostingController
    hostingController.rootView = AnyView(
      ItemPreview(
        item: item, blobStore: blobStore, imageMaxWidth: imageMaxWidth, onHover: onPreviewHover
      ).id(item.id))
    panel.contentViewController = hostingController
    let size = contentSize(
      for: item, hostingController: hostingController, imageMaxWidth: imageMaxWidth)
    panel.setContentSize(size)
    // Vertically center the popover on the pointer (which is over the hovered
    // row), so it appears beside that row rather than at the picker's top.
    positionPanel(
      panel, besideAnchor: anchorRect, on: side, atVerticalCenter: NSEvent.mouseLocation.y)
    // Never makeKey/makeKeyAndOrderFront — must not steal the search
    // field's first-responder status. See this file's top doc comment.
    panel.orderFrontRegardless()
  }

  /// Hides the preview panel, if shown. Safe to call even if already
  /// hidden/never shown.
  func hide() {
    panel?.orderOut(nil)
  }

  /// The panel's content size for `item`. A plain `.image` item (no
  /// recognized-text section) uses `boundedImageContentSize` — computed
  /// directly from known/bounded quantities, no SwiftUI layout involved.
  /// Everything else (text, file, or an image WITH a recognized-text
  /// section) still measures `hostingController.view.fittingSize`: those
  /// all legitimately depend on real text layout to size correctly (text is
  /// already length-capped per chunk, see `ItemPreview.TextPreview`, so
  /// this remaining `fittingSize` use is bounded/cheap, unlike the removed
  /// image case which had no such cap before T-PF3).
  private func contentSize(
    for item: ClipItem, hostingController: NSHostingController<AnyView>, imageMaxWidth: CGFloat
  ) -> NSSize {
    if item.kind == .image, !item.hasRecognizedText {
      return boundedImageContentSize(for: item, maxSide: imageMaxWidth)
    }
    let fittingSize = hostingController.view.fittingSize
    return NSSize(
      width: max(fittingSize.width, Self.minPanelWidth),
      height: max(fittingSize.height, Self.minPanelHeight))
  }

  /// Computes the popover's content size for a plain image preview (no
  /// recognized-text section) WITHOUT invoking SwiftUI layout — see this
  /// file's top doc comment (T-PF3 D4) for why that synchronous layout pass
  /// was the direct cause of the reported hang. The size is always exactly
  /// `ItemPreview.contentPadding` × 2 plus the image's own aspect-fit box
  /// (`ScaledImage.displaySize`, the SAME formula `ItemPreview` itself
  /// renders with — see that type's doc comment): if the image is already
  /// decoded and cached (`ItemThumbnailCache.preview`, a repeat hover), its
  /// real pixel size is used; on the very first hover of an image that
  /// isn't cached yet, `ItemPreview.imagePlaceholderSize` is used instead —
  /// the exact size `AsyncBlobImage` renders its "still loading" spinner
  /// box at, so this matches what's actually on screen at that moment
  /// (identical to what `fittingSize` would have measured then anyway,
  /// since the async decode hasn't produced a result yet either way).
  private func boundedImageContentSize(for item: ClipItem, maxSide: CGFloat) -> NSSize {
    let pixelSize =
      item.blobPath.flatMap { ItemThumbnailCache.preview.image(for: $0)?.size }
      ?? ItemPreview.imagePlaceholderSize
    let display = ScaledImage.displaySize(for: pixelSize, maxSide: maxSide)
    let chrome = ItemPreview.contentPadding * 2
    return NSSize(
      width: max(display.width + chrome, Self.minPanelWidth),
      height: max(display.height + chrome, Self.minPanelHeight))
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

  /// Places `panel` on the already-chosen `side` of `anchorRect` (the
  /// picker), vertically centered on `cursorY` (the pointer's screen Y, i.e.
  /// the hovered row) and clamped on-screen.
  ///
  /// The side is passed in rather than decided here: it is computed once in
  /// `update` from the picker's position alone, so it cannot vary with this
  /// particular item's panel width. Deciding it here, from `panel.frame.width`,
  /// is exactly what made the preview jump between left and right as the user
  /// moved down the list.
  private func positionPanel(
    _ panel: NSPanel,
    besideAnchor anchorRect: NSRect,
    on side: ClipnestViewModels.WindowPlacement.PreviewSide,
    atVerticalCenter cursorY: CGFloat
  ) {
    let width = panel.frame.width
    let height = panel.frame.height
    let visible =
      (NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main)?
      .visibleFrame ?? anchorRect
    let originX = ClipnestViewModels.WindowPlacement.previewOriginX(
      on: side,
      anchorRect: anchorRect,
      panelWidth: width,
      screenVisibleFrame: visible,
      gap: Self.gap)

    var origin = NSPoint(x: originX, y: cursorY - height / 2)
    origin.y = min(max(origin.y, visible.minY), visible.maxY - height)
    panel.setFrameOrigin(origin)
  }
}
