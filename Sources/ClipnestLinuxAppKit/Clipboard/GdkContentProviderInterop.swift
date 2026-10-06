// GdkContentProviderInterop.swift
//
// A small, LOCAL mirror of `ClipnestGTK/Interop/GTKShims.swift`'s
// documented pattern — see that file's own top doc comment for the full
// reasoning this deliberately reuses rather than reinventing (per this
// task's directive: "follow it rather than inventing a second
// convention"). It cannot literally reuse THAT file's shims, though:
// `GTKClipboardWriting.swift` lives in `ClipnestLinuxAppKit`, a DIFFERENT
// module from `ClipnestGTK`, and imports `CGtk4` directly rather than
// `ClipnestGTK` — so `GTKShims.swift`'s own shim functions (`internal`,
// invisible outside that module) aren't reachable from here, and widening
// that module's access levels (or reaching into it) is out of this file's
// scope (`Sources/ClipnestLinuxAppKit/Clipboard/**`). This file is the
// minimal equivalent for the one new GObject type this clipboard-write
// path needs, `GdkContentProvider`, following the identical reasoning and
// the identical "every force-unwrap confined to one documented file"
// discipline `GTKShims.swift` establishes — just with ordinary camelCase
// Swift names instead of same-named C overloads, since this file has a
// handful of call sites total, not the dozens across a whole view-layer
// module that motivated `GTKShims.swift`'s overload-shadowing trick.
//
// Both empirical findings below were VERIFIED against this exact GTK 4.6
// build (Ubuntu 22.04's `libgtk-4-dev`) by typechecking probe call sites
// against the real `CGtk4` module, NOT assumed — matching `GTKShims.swift`'s
// own verification discipline:
//
//  - `GdkContentProvider` DOES get its own named Swift type: its real
//    public header (`gdk/gdkcontentprovider.h`) declares a real
//    `struct _GdkContentProvider { GObject parent; };` body, unlike most
//    GTK4 widget types (which are fully opaque, `G_DECLARE_FINAL_TYPE`-
//    only, with no public struct body at all). So every function taking
//    or returning a `GdkContentProvider*` imports as
//    `UnsafeMutablePointer<GdkContentProvider>?`, not a plain
//    `OpaquePointer?`.
//  - `GBytes` does NOT get a named Swift type: `glib/garray.h` declares it
//    as a fully opaque `typedef struct _GBytes GBytes;` with no public
//    field body anywhere — so every function taking or returning a
//    `GBytes*` was ALREADY a plain `OpaquePointer?` on both sides, zero
//    casting needed, exactly like `GTKShims.swift`'s own "NO named Swift
//    type" group (`GtkListBox`, `GtkImage`, ...).
//
// Every constructor below (`gdk_content_provider_new_for_bytes`/
// `_new_union`) force-unwraps and returns a plain, already-unwrapped
// `OpaquePointer` — matching `GTKShims.swift`'s own rationale exactly:
// neither is documented nullable (verified against the real
// `Gdk-4.0.gir` introspection data this exact build ships) for a
// well-formed, non-NULL `mime_type`/`bytes`/`providers` argument, the ONLY
// way this file ever calls them — a NULL return here would mean the
// process is in a state (out of memory, GTK not initialized) with no sane
// recovery, the identical class of "this cannot fail in a running GTK
// app" assumption `GTKShims.swift` already accepts for every widget
// constructor it wraps.
//
// **Ownership, verified against `Gdk-4.0.gir`'s `transfer-ownership`
// annotations for every call below (not assumed — see this task's own
// "ownership matters here" directive):**
//  - `g_bytes_new(data, size)`: `data` is `transfer-ownership="none"` AND
//    documented as COPIED ("data is copied") — so the caller's own buffer
//    is free to be deallocated the instant this call returns, no dangling-
//    pointer risk. Its return is `transfer-ownership="full"` — the caller
//    owns the returned `GBytes` and must eventually `g_bytes_unref` it.
//  - `gdk_content_provider_new_for_bytes(mime_type, bytes)`: `bytes` is
//    `transfer-ownership="none"` — the provider refs it internally but
//    does NOT consume the caller's own reference, so the caller must
//    still `g_bytes_unref` its own `bytes` reference right after this
//    call (every call site below does so immediately). Its return is
//    `transfer-ownership="full"` — the caller owns the returned provider.
//  - `gdk_content_provider_new_union(providers, n)`: `providers` is
//    `transfer-ownership="full"` — the union CONSUMES every reference in
//    the array; callers must NOT separately unref the individual
//    providers passed in, only the resulting union provider. Its return
//    is `transfer-ownership="full"` too.
//  - `gdk_clipboard_set_content(clipboard, provider)`: `provider` is
//    `transfer-ownership="none"` — `GdkClipboard` refs whatever it needs
//    internally; the caller still owns its own `provider` reference after
//    this call and must release it (`g_object_unref`) once done, which is
//    exactly what `GTKClipboardWriting` does immediately after every
//    `set_content` call.
import CGtk4
import Foundation

private func gdkContentProviderPointer(_ pointer: OpaquePointer) -> UnsafeMutablePointer<
  GdkContentProvider
> {
  UnsafeMutablePointer<GdkContentProvider>(pointer)
}

/// `g_bytes_new` (GLib, not GTK/GDK — see this file's own doc comment for
/// why it still belongs here): copies `data` into a new, GLib-owned buffer
/// before returning, so `data`'s own storage is free to be deallocated by
/// its caller (typically as soon as this function returns) with no
/// dangling-pointer risk. See this file's top doc comment for the full
/// ownership contract every call site here relies on.
func gBytesNew(_ data: Data) -> OpaquePointer {
  data.withUnsafeBytes { buffer in
    g_bytes_new(buffer.baseAddress, UInt(buffer.count))!
  }
}

/// Releases a `GBytes` reference this file created via `gBytesNew` — call
/// exactly once per `gBytesNew`, immediately after handing it to
/// `gdkContentProviderNewForBytes` (which refs it internally rather than
/// consuming this reference — see this file's top doc comment).
func gBytesUnref(_ bytes: OpaquePointer) {
  g_bytes_unref(bytes)
}

/// A content provider offering `bytes` as `mimeType`'s payload. Returns a
/// reference the caller owns (`transfer-ownership="full"`) — either hand
/// it to `gdkContentProviderNewUnion` (which consumes it) or to
/// `gdkClipboardSetContent` followed by `gObjectUnref` (which does not).
func gdkContentProviderNewForBytes(mimeType: String, bytes: OpaquePointer) -> OpaquePointer {
  OpaquePointer(gdk_content_provider_new_for_bytes(mimeType, bytes)!)
}

/// A single content provider offering every representation in `providers`
/// — GDK tries them in the given order and answers a reader's request
/// with whichever first supports the requested MIME type. CONSUMES every
/// reference in `providers` (`transfer-ownership="full"` — see this
/// file's top doc comment): callers must not separately `gObjectUnref`
/// any element of `providers` after this call, only the returned union
/// provider.
func gdkContentProviderNewUnion(_ providers: [OpaquePointer]) -> OpaquePointer {
  var typed: [UnsafeMutablePointer<GdkContentProvider>?] = providers.map(gdkContentProviderPointer)
  return typed.withUnsafeMutableBufferPointer { buffer in
    OpaquePointer(gdk_content_provider_new_union(buffer.baseAddress, UInt(buffer.count))!)
  }
}

/// Sets `clipboard`'s content to `provider` — does NOT consume the
/// caller's `provider` reference (see this file's top doc comment); the
/// caller must still `gObjectUnref` it once this returns. Returns `false`
/// on GDK's own rare documented failure path (the clipboard then keeps
/// its previous content) — never force-unwrapped/crashed, per
/// coding-standards.md's error-handling pattern.
@discardableResult
func gdkClipboardSetContent(_ clipboard: OpaquePointer, _ provider: OpaquePointer) -> Bool {
  gdk_clipboard_set_content(clipboard, gdkContentProviderPointer(provider)) != 0
}

/// Releases a `GdkContentProvider` reference this file owns (from
/// `gdkContentProviderNewForBytes`/`gdkContentProviderNewUnion`) — never
/// call this on a provider already handed to `gdkContentProviderNewUnion`
/// (which already consumed it — see this file's top doc comment).
func gObjectUnref(_ provider: OpaquePointer) {
  g_object_unref(gdkContentProviderPointer(provider))
}
