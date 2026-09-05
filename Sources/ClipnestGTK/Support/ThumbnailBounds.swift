// ThumbnailBounds.swift
//
// P7-D (Linux port, GTK4 view layer): pure bounded-decode-size arithmetic —
// the load-bearing fix this task was explicitly warned not to regress (see
// project-context.md decisions D42-D45: the macOS build shipped a P0 hang
// from decoding a 25 MB screenshot at FULL resolution just to draw a 20pt
// row icon; `ImageThumbnailDecoder.swift` fixed it there with
// `CGImageSourceCreateThumbnailAtIndex(..., maxPixelSize:)`, which decodes
// straight to a bounded bitmap instead of ever allocating a full-resolution
// one). This is the GTK equivalent: `PickerWindow+Preview.swift`'s
// `GdkPixbufLoader` "size-prepared" handler (the untestable GTK edge) calls
// `boundedSize(...)` and feeds the result to `gdk_pixbuf_loader_set_size`
// BEFORE any pixel data is decoded, so the loader itself never allocates a
// full-resolution buffer — this file is what makes that call correct.
public enum ThumbnailBounds {
  /// The largest edge (pixels) a picker ROW's leading icon/thumbnail is
  /// ever decoded at. This picker never draws a row thumbnail larger than
  /// its own fixed row height; decoding past that would repeat the exact
  /// D42-D45 hang for no visual benefit. Generous headroom over the drawn
  /// size for HiDPI/fractional-scaling displays.
  public static let rowIconMaxPixelSize = 64

  /// The largest edge the hover-preview popover's image is decoded at —
  /// larger than a row icon (the popover exists to show detail), but still
  /// a hard, named ceiling rather than the source image's own resolution.
  public static let previewMaxPixelSize = 512

  /// Computes the `(width, height)` to decode an image at, given its
  /// ORIGINAL pixel dimensions and a `maxPixelSize` ceiling on the longer
  /// edge — aspect-ratio preserved, never upscaled past the original (a
  /// small source stays its own size, matching `ImageThumbnailDecoder`'s
  /// macOS behavior). Returns `(1, 1)` for a degenerate (non-positive)
  /// source size instead of dividing by zero — `GdkPixbuf` would reject a
  /// zero-sized target anyway, and `(1, 1)` is a safe, harmless floor.
  public static func boundedSize(
    originalWidth: Int, originalHeight: Int, maxPixelSize: Int
  ) -> (width: Int, height: Int) {
    guard originalWidth > 0, originalHeight > 0, maxPixelSize > 0 else { return (1, 1) }
    let longerEdge = max(originalWidth, originalHeight)
    guard longerEdge > maxPixelSize else { return (originalWidth, originalHeight) }
    let scale = Double(maxPixelSize) / Double(longerEdge)
    let width = max(1, Int((Double(originalWidth) * scale).rounded()))
    let height = max(1, Int((Double(originalHeight) * scale).rounded()))
    return (width, height)
  }
}
