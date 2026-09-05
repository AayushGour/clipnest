// GTKNumericConversions.swift
//
// P7-D (Linux port, GTK4 view layer): named `Int` -> `gint`-shaped (`Int32`)
// conversion for handing a pure-logic constant (`ThumbnailBounds`,
// `ScrollPaging`, ...) to a GTK C call — one place, so the C-interop
// boundary's numeric-width conversions are grep-able rather than a bare
// `Int32(...)` scattered at each call site (coding-standards.md DRY/
// consistency).
extension Int {
  var gtkInt32: Int32 { Int32(self) }
}
