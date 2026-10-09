// PreviewAnchor.swift
//
// Pure geometry for where the hover-preview popover is anchored. macOS
// (`ItemPreviewController` + `WindowPlacement.previewSide`) places the preview
// beside the picker, level with the hovered row. GTK4 has no client-side
// window positioning and, on Wayland, the app cannot know where its window is
// on screen, so it cannot compute the side itself. Instead the popover
// (`GTK_POS_RIGHT`) is pointed at a band that spans the WHOLE window width at
// the hovered row's height: the popover then lands just outside the window's
// right edge, and the compositor flips it to the left when there is no room
// (xdg_popup positioner flip constraints).
public enum PreviewAnchor {
  /// Gap in pixels between the window edge and the preview.
  public static let gap: Int32 = 8

  public struct Band: Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
  }

  /// The anchor band in the popover parent's coordinate space. `windowLeft` is
  /// the window's left edge expressed in that space (typically <= 0: the
  /// parent sits inside the window's margins), `rowTop` the hovered row's
  /// top. The row's vertical extent is clipped to the visible viewport
  /// (`visibleTop`/`visibleHeight`): a row partly scrolled out of view must not
  /// push the anchor beyond the window, which xdg_positioner forbids. A row
  /// wholly outside collapses to a 1px band at the nearest viewport edge.
  /// Width and height are clamped to at least 1 so GTK never receives an empty
  /// rect (an unallocated widget reports 0).
  public static func band(
    windowLeft: Int, windowWidth: Int, rowTop: Int, rowHeight: Int,
    visibleTop: Int, visibleHeight: Int
  ) -> Band {
    let visibleBottom = visibleTop + max(visibleHeight, 1)
    let top = min(max(rowTop, visibleTop), visibleBottom - 1)
    let bottom = min(max(rowTop + rowHeight, top + 1), visibleBottom)
    return Band(x: windowLeft, y: top, width: max(windowWidth, 1), height: bottom - top)
  }
}
