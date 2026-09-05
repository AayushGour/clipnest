// PickerWindow+Preview.swift
//
// P7-D (Linux port, GTK4 view layer): hover preview. Hover DETECTION and
// timing reuse `PickerViewModel.hoverItem(_:)`/`.previewHoverChanged(_:)`
// (`PickerViewModel+Preview.swift` — its existing show/close-grace debounce,
// not re-implemented here); this file only (1) tells the view model which
// row is under the pointer, via a single `GtkEventControllerMotion` on
// `listBox` (using `gtk_list_box_get_row_at_y`, so no per-row controller is
// needed), and (2) renders whatever `previewTargetID` the view model
// settles on, once `PickerWindow+Polling.swift` notices it changed.
//
// BOUNDED DECODE (the load-bearing requirement this task called out by
// name — see project-context.md D42-D45): `GdkPixbufLoader`'s
// "size-prepared" signal fires once the loader knows the source image's
// real pixel dimensions but BEFORE it decodes a single pixel.
// `gdk_pixbuf_loader_set_size(...)`, called from that handler, makes the
// loader decode DIRECTLY to the given size — it never allocates a
// full-resolution bitmap at all. `ThumbnailBounds.boundedSize(...)`
// (`Support/`, pure and unit-tested) computes that target size; this file
// only wires it to the two GTK calls that need it.
import CGtk4
import ClipnestCore

/// Retained for the lifetime of one `GdkPixbufLoader` decode (see
/// `Interop/GTKCallbackTrampoline.swift`) — carries the bound the
/// "size-prepared" handler must enforce. A fresh instance per decode
/// (unlike `PickerWindow` itself, connected once for the window's whole
/// lifetime) since each hover potentially decodes a different image.
final class PixbufSizeBound {
  let maxPixelSize: Int
  init(maxPixelSize: Int) {
    self.maxPixelSize = maxPixelSize
  }
}

extension PickerWindow {
  func connectPreviewMotion() {
    let controller: OpaquePointer = gtk_event_controller_motion_new()
    gtkConnect(
      controller, signal: "motion", context: self,
      callback: unsafeBitCast(previewMotionTrampoline, to: GCallback.self))
    gtkConnect(
      controller, signal: "leave", context: self,
      callback: unsafeBitCast(previewLeaveTrampoline, to: GCallback.self))
    gtk_widget_add_controller(listBox, controller)
  }

  func handlePreviewMotion(x: Double, y: Double) {
    guard let row = gtk_list_box_get_row_at_y(listBox, Int32(y)) else {
      handlePreviewLeave()
      return
    }
    let index = Int(gtk_list_box_row_get_index(row))
    let hoveredID: ClipItem.ID? =
      MainActor.assumeIsolated {
        guard viewModel.activeTab != .snippets, renderedRows.indices.contains(index) else {
          return nil
        }
        return renderedRows[index].id
      }
    lastHoverPoint = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
    MainActor.assumeIsolated {
      viewModel.hoverItem(hoveredID)
    }
  }

  func handlePreviewLeave() {
    MainActor.assumeIsolated {
      viewModel.hoverItem(nil)
    }
  }

  /// Called by `PickerWindow+Polling.swift` when a poll tick notices
  /// `previewTargetID` changed. Resolves the target `ClipItem` from
  /// `renderedRows` (mirroring how `PickerView` resolves it from `rows` on
  /// macOS before calling `updatePreview` — see that property's doc
  /// comment) and shows/updates/hides the popover.
  func updatePreviewPopover(targetID: ClipItem.ID?) {
    guard let targetID, let item = renderedRows.first(where: { $0.id == targetID }) else {
      gtk_popover_popdown(previewPopover)
      return
    }

    if var rect = lastHoverPoint {
      gtk_popover_set_pointing_to(previewPopover, &rect)
    }

    switch item.kind {
    case .image:
      gtk_widget_set_visible(previewImage, 1)
      gtk_label_set_text(previewLabel, item.previewText)
      decodeBoundedThumbnail(for: item)
    case .text, .richText, .link, .file:
      gtk_widget_set_visible(previewImage, 0)
      gtk_label_set_text(previewLabel, item.previewText)
    }
    gtk_popover_popup(previewPopover)
  }

  /// Reads `item`'s blob and decodes it through a `GdkPixbufLoader` bounded
  /// to `ThumbnailBounds.previewMaxPixelSize` — see this file's top doc
  /// comment. Synchronous (a hover-triggered, already-on-disk blob read is
  /// not the unbounded full-resolution DECODE that caused D42-D45's hang;
  /// a fully async pipeline is a reasonable follow-up but out of this
  /// task's scope).
  private func decodeBoundedThumbnail(for item: ClipItem) {
    guard let blobPath = item.blobPath,
      let data = try? MainActor.assumeIsolated({ try viewModel.blobStore.read(blobPath: blobPath) }
      )
    else {
      gtk_widget_set_visible(previewImage, 0)
      return
    }

    let loader: OpaquePointer = gdk_pixbuf_loader_new()
    let bound = PixbufSizeBound(maxPixelSize: ThumbnailBounds.previewMaxPixelSize)
    gtkConnect(
      loader, signal: "size-prepared", context: bound,
      callback: unsafeBitCast(sizePreparedTrampoline, to: GCallback.self))

    let decoded: OpaquePointer? = data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return nil }
      let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
      guard gdk_pixbuf_loader_write(loader, bytes, UInt(rawBuffer.count)) != 0 else {
        return nil
      }
      guard gdk_pixbuf_loader_close(loader) != 0 else { return nil }
      return gdk_pixbuf_loader_get_pixbuf(loader)
    }

    guard let pixbuf = decoded else {
      gtk_widget_set_visible(previewImage, 0)
      return
    }
    gtk_image_set_from_pixbuf(previewImage, pixbuf)
  }
}

/// `GtkEventControllerMotion::motion` — `void (*)(GtkEventControllerMotion*,
/// gdouble x, gdouble y, gpointer)`.
private let previewMotionTrampoline:
  @convention(c) (
    OpaquePointer?, Double, Double, UnsafeMutableRawPointer?
  ) -> Void = { _, x, y, data in
    guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
    window.handlePreviewMotion(x: x, y: y)
  }

/// `GtkEventControllerMotion::leave` — `void (*)(GtkEventControllerMotion*, gpointer)`.
private let previewLeaveTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
      window.handlePreviewLeave()
    }

/// `GdkPixbufLoader::size-prepared` — `void (*)(GdkPixbufLoader*, gint width,
/// gint height, gpointer)`.
private let sizePreparedTrampoline:
  @convention(c) (
    OpaquePointer?, Int32, Int32, UnsafeMutableRawPointer?
  ) -> Void = { loader, width, height, data in
    guard let loader, let bound = unretainedContext(data, as: PixbufSizeBound.self) else { return }
    let bounded = ThumbnailBounds.boundedSize(
      originalWidth: Int(width), originalHeight: Int(height), maxPixelSize: bound.maxPixelSize)
    gdk_pixbuf_loader_set_size(loader, bounded.width.gtkInt32, bounded.height.gtkInt32)
  }
