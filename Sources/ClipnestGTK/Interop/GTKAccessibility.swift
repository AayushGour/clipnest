// GTKAccessibility.swift
//
// T-WELCOME1-LX: thin wrappers over GtkAccessible (Orca). `gtk_accessible_
// update_property` is C-variadic and so not callable from Swift; the
// `_value` variants take explicit arrays and are, with GValues built here.
// Live-region announcements need `gtk_accessible_announce`, which only exists
// in GTK >= 4.14 (Ubuntu 22.04 ships 4.6), so it is looked up at runtime and
// silently skipped when absent (status text still updates in place).
import CGtk4

#if canImport(Glibc)
  import Glibc
#endif

enum GTKAccessibility {
  private static let stringTypeName = "gchararray"
  private static let booleanTypeName = "gboolean"

  /// Sets the widget's accessible name (what Orca reads for it).
  static func setLabel(_ widget: OpaquePointer, _ text: String) {
    var value = GValue()
    g_value_init(&value, g_type_from_name(stringTypeName))
    g_value_set_string(&value, text)
    var property = GTK_ACCESSIBLE_PROPERTY_LABEL
    gtk_accessible_update_property_value(accessible(widget), 1, &property, &value)
    g_value_unset(&value)
  }

  /// Hides a purely decorative widget from assistive tech.
  static func setHidden(_ widget: OpaquePointer, _ hidden: Bool) {
    var value = GValue()
    g_value_init(&value, g_type_from_name(booleanTypeName))
    g_value_set_boolean(&value, hidden ? 1 : 0)
    var state = GTK_ACCESSIBLE_STATE_HIDDEN
    gtk_accessible_update_state_value(accessible(widget), 1, &state, &value)
    g_value_unset(&value)
  }

  private typealias AnnounceFunction =
    @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32) -> Void
  private static let mediumPriority: Int32 = 1  // GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM
  private static let announceSymbol = "gtk_accessible_announce"

  /// Polite live-region announcement; no-op on GTK < 4.14.
  static func announce(_ widget: OpaquePointer, _ message: String) {
    #if canImport(Glibc)
      guard let symbol = dlsym(nil, announceSymbol) else { return }
      let function = unsafeBitCast(symbol, to: AnnounceFunction.self)
      message.withCString { function(widget, $0, mediumPriority) }
    #endif
  }

  private static func accessible(_ widget: OpaquePointer) -> OpaquePointer {
    widget
  }
}
