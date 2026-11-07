// GTKShimsForRowActionsAndEditor.swift
//
// Linux parity pass (routed follow-up, 2026-09-06): small GTK API surface
// this task needs that `Interop/GTKShims.swift` doesn't shim yet — this
// task's owned-files scope is `Sources/ClipnestGTK/Window/*.swift` only, not
// `Interop/GTKShims.swift`, so these live here instead. Exact same reasoning
// (and same "verify empirically, don't assume" discipline) as `SettingsWindow
// +Controls.swift`'s own "MARK: - GTK shims not yet in Interop/GTKShims.swift"
// section — see that file's doc comment for the full rationale this mirrors.
// Every constructor returns a plain, already-unwrapped `OpaquePointer`; every
// other function takes `OpaquePointer` and casts internally via `gtkPointer`
// only where the real C signature needs a more specific pointer type — same
// convention `Interop/GTKShims.swift`'s top doc comment documents once for
// the whole module.
//
// `GtkGestureClick`/`GtkGestureSingle` (context-menu right-click detection),
// `GtkTextView`/`GtkTextBuffer` (the snippet editor's multi-line Body field),
// and `GtkEntry`'s placeholder-text setter are new to this module as of this
// task — none was previously exercised by `PickerWindow`/`SettingsWindow`.
//
// Lint note: each function below carries its OWN `// swift-format-ignore:
// AlwaysUseLowerCamelCase` line rather than one file-wide `// swift-format
// -ignore-file: AlwaysUseLowerCamelCase` directive — verified empirically
// (a real `swift format lint --strict` run, not assumed) that this
// toolchain's `lint` subcommand does not honor the file-wide directive at
// all (it still flags every C-named function), while the per-declaration
// directive `SettingsWindow+Controls.swift` already uses IS honored. Matches
// that file's convention exactly, not `Interop/GTKShims.swift`'s (whose
// file-wide directive form appears to be a latent, pre-existing lint gap
// there, outside this task's owned-files scope to fix).
import CGtk4

// MARK: - GtkButton (a real named type, per Interop/GTKShims.swift's survey)

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_button_new_from_icon_name(_ iconName: String) -> OpaquePointer {
  OpaquePointer(gtk_button_new_from_icon_name(iconName)!)
}

// MARK: - GtkWidget (a real named type)

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_widget_set_sensitive(_ widget: OpaquePointer, _ sensitive: Int32) {
  gtk_widget_set_sensitive(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, sensitive)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_widget_get_sensitive(_ widget: OpaquePointer) -> Int32 {
  gtk_widget_get_sensitive(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_widget_get_visible(_ widget: OpaquePointer) -> Int32 {
  gtk_widget_get_visible(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>)
}

// MARK: - GtkWindow (a real named type)

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_window_close(_ window: OpaquePointer) {
  gtk_window_close(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>)
}

// MARK: - GtkEntry (a real named type, per Interop/GTKShims.swift's
// `gtk_entry_new()` constructor shim already wrapping its result)

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_entry_set_placeholder_text(_ entry: OpaquePointer, _ text: String) {
  gtk_entry_set_placeholder_text(gtkPointer(entry) as UnsafeMutablePointer<GtkEntry>, text)
}

// MARK: - GtkTextView / GtkTextBuffer (new to this module)

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_view_new() -> OpaquePointer {
  OpaquePointer(gtk_text_view_new()!)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_view_get_buffer(_ textView: OpaquePointer) -> OpaquePointer {
  OpaquePointer(
    gtk_text_view_get_buffer(gtkPointer(textView) as UnsafeMutablePointer<GtkTextView>)!)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_view_set_wrap_mode(_ textView: OpaquePointer, _ mode: GtkWrapMode) {
  gtk_text_view_set_wrap_mode(gtkPointer(textView) as UnsafeMutablePointer<GtkTextView>, mode)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_view_set_editable(_ textView: OpaquePointer, _ editable: Int32) {
  gtk_text_view_set_editable(gtkPointer(textView) as UnsafeMutablePointer<GtkTextView>, editable)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_view_set_accepts_tab(_ textView: OpaquePointer, _ acceptsTab: Int32) {
  gtk_text_view_set_accepts_tab(
    gtkPointer(textView) as UnsafeMutablePointer<GtkTextView>, acceptsTab)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_window_set_default_widget(_ window: OpaquePointer, _ widget: OpaquePointer?) {
  gtk_window_set_default_widget(
    gtkPointer(window) as UnsafeMutablePointer<GtkWindow>,
    widget.map { gtkPointer($0) as UnsafeMutablePointer<GtkWidget> })
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_buffer_set_text(_ buffer: OpaquePointer, _ text: String, _ length: Int32) {
  gtk_text_buffer_set_text(gtkPointer(buffer) as UnsafeMutablePointer<GtkTextBuffer>, text, length)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_buffer_get_start_iter(_ buffer: OpaquePointer, _ iter: inout GtkTextIter) {
  gtk_text_buffer_get_start_iter(gtkPointer(buffer) as UnsafeMutablePointer<GtkTextBuffer>, &iter)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_buffer_get_end_iter(_ buffer: OpaquePointer, _ iter: inout GtkTextIter) {
  gtk_text_buffer_get_end_iter(gtkPointer(buffer) as UnsafeMutablePointer<GtkTextBuffer>, &iter)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_buffer_get_text(
  _ buffer: OpaquePointer, _ start: inout GtkTextIter, _ end: inout GtkTextIter,
  _ includeHiddenChars: Int32
) -> UnsafeMutablePointer<CChar>? {
  gtk_text_buffer_get_text(
    gtkPointer(buffer) as UnsafeMutablePointer<GtkTextBuffer>, &start, &end, includeHiddenChars)
}

// MARK: - GtkGestureClick / GtkGestureSingle (new to this module — the
// context menu's right-click detector, `PickerWindow+ContextMenu.swift`)
//
// Verified empirically (a real `swift build` attempt, not assumed — see
// this file's top doc comment): neither `GtkGestureClick` nor
// `GtkGestureSingle` gets its own named Swift type on this GTK 4.6 build —
// the whole `GtkGesture`/`GtkEventController` family is apparently
// consistent on that point (`Interop/GTKShims.swift`'s top doc comment
// already confirmed this for `GtkEventControllerKey`/`Motion`). So
// `gtk_gesture_click_new()` only needs its `OpaquePointer!` force-unwrapped
// (same shape as that file's `gtk_event_controller_key_new()`/
// `_motion_new()` — no `OpaquePointer(...)` wrapping constructor call, which
// is only for types THAT DO get a named type), and
// `gtk_gesture_single_set_button` needs no shim at all: every parameter
// already matches the real imported signature exactly, so a same-named
// wrapper here would just call itself — the identical "infinite recursion"
// class of mistake `Interop/GTKShims.swift`'s own `gtk_scrolled_window
// _set_policy` note already documents. Called directly at its one call
// site (`PickerWindow+ContextMenu.swift`) instead.

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_gesture_click_new() -> OpaquePointer {
  gtk_gesture_click_new()!
}

// MARK: - GtkTextBuffer styling (T-EDIT9 item editor)
//
// `GtkTextTag` properties are set through `g_object_set_property` with an
// explicit `GValue`, not `g_object_set`/`gtk_text_buffer_create_tag` — both are
// C variadics, which Swift cannot call. Fundamental GTypes are
// `ordinal << G_TYPE_FUNDAMENTAL_SHIFT`; the `G_TYPE_*` macros that compute
// that are not imported, so the ordinals are named here once.

enum GTKTextStyling {
  private static let fundamentalShift: GType = 2
  private static let intOrdinal: GType = 6
  private static let stringOrdinal: GType = 16
  private static let doubleOrdinal: GType = 15
  /// `G_TYPE_STRING`.
  static var stringType: GType { stringOrdinal << fundamentalShift }

  /// `PANGO_WEIGHT_BOLD`, `PANGO_STYLE_ITALIC`, `PANGO_UNDERLINE_SINGLE`.
  private static let boldWeight: Int32 = 700
  private static let italicStyle: Int32 = 2
  private static let singleUnderline: Int32 = 1

  /// Creates a named tag in `buffer`'s tag table styled by `name` (one of
  /// the `ItemEditorTagNames` forms), or returns the existing one. Returns
  /// nil for a name that carries no style (unknown prefix, bad colour).
  static func tag(named name: String, in buffer: OpaquePointer) -> OpaquePointer? {
    let textBuffer: UnsafeMutablePointer<GtkTextBuffer> = gtkPointer(buffer)
    let table = gtk_text_buffer_get_tag_table(textBuffer)
    if let existing = gtk_text_tag_table_lookup(table, name) { return OpaquePointer(existing) }
    guard let tag = gtk_text_tag_new(name) else { return nil }
    guard configure(tag, for: name) else {
      g_object_unref(UnsafeMutableRawPointer(tag))
      return nil
    }
    gtk_text_tag_table_add(table, tag)
    // The table holds its own reference; drop the creation reference.
    g_object_unref(UnsafeMutableRawPointer(tag))
    return OpaquePointer(tag)
  }

  private static func configure(_ tag: UnsafeMutablePointer<GtkTextTag>, for name: String) -> Bool {
    switch name {
    case ItemEditorTagNames.bold: return setInt(tag, "weight", boldWeight)
    case ItemEditorTagNames.italic:
      return setEnum(tag, "style", pango_style_get_type(), italicStyle)
    case ItemEditorTagNames.underline:
      return setEnum(tag, "underline", pango_underline_get_type(), singleUnderline)
    default:
      if name.hasPrefix(ItemEditorTagNames.colorPrefix) {
        return setColor(tag, String(name.dropFirst(ItemEditorTagNames.colorPrefix.count)))
      }
      if name.hasPrefix(ItemEditorTagNames.familyPrefix) {
        let family = String(name.dropFirst(ItemEditorTagNames.familyPrefix.count))
        return setString(tag, "family", family)
      }
      if name.hasPrefix(ItemEditorTagNames.sizePrefix),
        let points = Double(name.dropFirst(ItemEditorTagNames.sizePrefix.count))
      {
        return setDouble(tag, "size-points", points)
      }
      return false
    }
  }

  private static func withValue(
    _ tag: UnsafeMutablePointer<GtkTextTag>, _ property: String, type: GType,
    _ fill: (UnsafeMutablePointer<GValue>) -> Void
  ) -> Bool {
    var value = GValue()
    g_value_init(&value, type)
    defer { g_value_unset(&value) }
    fill(&value)
    g_object_set_property(
      gtkPointer(OpaquePointer(tag)) as UnsafeMutablePointer<GObject>, property, &value)
    return true
  }

  private static func setInt(
    _ tag: UnsafeMutablePointer<GtkTextTag>, _ property: String, _ v: Int32
  ) -> Bool {
    withValue(tag, property, type: intOrdinal << fundamentalShift) { g_value_set_int($0, v) }
  }

  /// `style` and `underline` are GObject ENUM properties: GLib registers
  /// enum -> int transforms but not int -> enum, so a `gint` GValue would be
  /// rejected (GLib-CRITICAL) and the tag would have no effect.
  private static func setEnum(
    _ tag: UnsafeMutablePointer<GtkTextTag>, _ property: String, _ type: GType, _ v: Int32
  ) -> Bool { withValue(tag, property, type: type) { g_value_set_enum($0, v) } }

  /// Test seam: the (weight, style, underline) a tag named `name` ends up
  /// with, read back through GObject, or nil if no tag was created.
  /// GtkTextTag/GtkTextBuffer need no display.
  static func readBackStyle(forTagNamed name: String)
    -> (weight: Int32, style: Int32, underline: Int32)?
  {
    let buffer = OpaquePointer(gtk_text_buffer_new(nil)!)
    defer { g_object_unref(UnsafeMutableRawPointer(buffer)) }
    guard let tag = tag(named: name, in: buffer) else { return nil }
    func read(_ property: String, _ type: GType) -> Int32 {
      var value = GValue()
      g_value_init(&value, type)
      defer { g_value_unset(&value) }
      g_object_get_property(
        gtkPointer(tag) as UnsafeMutablePointer<GObject>, property, &value)
      return type == intOrdinal << fundamentalShift
        ? g_value_get_int(&value) : g_value_get_enum(&value)
    }
    return (
      read("weight", intOrdinal << fundamentalShift), read("style", pango_style_get_type()),
      read("underline", pango_underline_get_type())
    )
  }

  private static func setDouble(
    _ tag: UnsafeMutablePointer<GtkTextTag>, _ property: String, _ v: Double
  ) -> Bool {
    withValue(tag, property, type: doubleOrdinal << fundamentalShift) { g_value_set_double($0, v) }
  }

  private static func setString(
    _ tag: UnsafeMutablePointer<GtkTextTag>, _ property: String, _ v: String
  ) -> Bool {
    withValue(tag, property, type: stringOrdinal << fundamentalShift) { g_value_set_string($0, v) }
  }

  /// `foreground-rgba` is a boxed `GdkRGBA`, so it needs the boxed GType
  /// (`gdk_rgba_get_type()`), not a fundamental ordinal.
  private static func setColor(_ tag: UnsafeMutablePointer<GtkTextTag>, _ hex: String) -> Bool {
    var rgba = GdkRGBA()
    guard gdk_rgba_parse(&rgba, hex) != 0 else { return false }
    var value = GValue()
    g_value_init(&value, gdk_rgba_get_type())
    defer { g_value_unset(&value) }
    g_value_set_boxed(&value, &rgba)
    g_object_set_property(
      gtkPointer(OpaquePointer(tag)) as UnsafeMutablePointer<GObject>, "foreground-rgba", &value)
    return true
  }
}

// MARK: - Editor popups (T-EDIT14 / T-EDIT15)

/// A literal tab at the cursor, replacing any selection. Used for Ctrl+Tab in
/// the item editor and the snippet Body (both set `accepts-tab` off, so Tab
/// moves focus).
func gtkInsertLiteralTab(into buffer: OpaquePointer) {
  let pointer: UnsafeMutablePointer<GtkTextBuffer> = gtkPointer(buffer)
  gtk_text_buffer_delete_selection(pointer, 1, 1)
  gtk_text_buffer_insert_at_cursor(pointer, "\t", 1)
}

/// Sets the accessible name Orca reads for `widget` (GTK_ACCESSIBLE_PROPERTY_LABEL).
/// Uses the non-variadic `_value` form: Swift can't call the variadic one.
func gtkSetAccessibleLabel(_ widget: OpaquePointer, _ label: String) {
  var property = GTK_ACCESSIBLE_PROPERTY_LABEL
  var value = GValue()
  g_value_init(&value, GTKTextStyling.stringType)
  defer { g_value_unset(&value) }
  g_value_set_string(&value, label)
  gtk_accessible_update_property_value(
    widget, 1, &property, &value)
}
