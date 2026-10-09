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
  /// top. Width and height are clamped to at least 1 so GTK never receives an
  /// empty rect (an unallocated widget reports 0).
  public static func band(
    windowLeft: Int, windowWidth: Int, rowTop: Int, rowHeight: Int
  ) -> Band {
    Band(x: windowLeft, y: rowTop, width: max(windowWidth, 1), height: max(rowHeight, 1))
  }
}
