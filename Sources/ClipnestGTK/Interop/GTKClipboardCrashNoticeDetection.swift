// GTKClipboardCrashNoticeDetection.swift
//
// T-WB1-GTKBUMP: the untestable GTK/GDK edge behind `GTKClipboardCrashNoticeInfo`
// (`Support/GTKClipboardCrashNotice.swift`) — a direct FFI read with no pure
// decision left inside it to unit-test; that file's own decision logic
// (`GTKClipboardCrashNoticePresentation.shouldShow(for:)`) is what
// `Tests/ClipnestPlatformLinuxTests/` covers, with injected version
// numbers, mirroring `X11WindowTypeHint.swift`'s identical "real GTK/X11
// side effect, no pure logic left to test, verified instead at runtime"
// note.
//
// Must only be called after `ClipnestGTKApplication.initializeGTK()` has
// run (`gtk_init()`) — before that, `gdk_display_get_default()` returns
// `nil`, which this function treats as "not X11" (fail closed: never
// report X11 without a real, already-opened display backing that claim).
import CGdkX11
import CGtk4

public enum GTKClipboardCrashNoticeDetection {
  /// Resolves the two live facts `GTKClipboardCrashNoticeInfo` needs from
  /// the actual running process. Safe to call exactly once, at
  /// composition-root startup (`LinuxAppEnvironment.init`) — see that
  /// struct's doc comment for why neither fact can change during this
  /// process's lifetime.
  public static func detectCurrent() -> GTKClipboardCrashNoticeInfo {
    let version = GTKRuntimeVersion(
      major: Int(gtk_get_major_version()),
      minor: Int(gtk_get_minor_version()),
      micro: Int(gtk_get_micro_version()))
    let isX11Backend = gdk_display_get_default().map(gdkDisplayIsX11) ?? false
    return GTKClipboardCrashNoticeInfo(runtimeVersion: version, isX11Backend: isX11Backend)
  }
}

/// True iff `display` is backed by GDK's X11 backend, realized via
/// `Sources/CGdkX11/shim.h`'s `clipnest_gdk_display_is_x11` — see that
/// function's doc comment for why this is a live `GDK_IS_X11_DISPLAY`
/// query rather than an env-var heuristic.
private func gdkDisplayIsX11(_ display: OpaquePointer) -> Bool {
  clipnest_gdk_display_is_x11(display) != 0
}
