// GTKCallbackTrampoline.swift
//
// P7-D (Linux port, GTK4 view layer): THE ONE PLACE this module documents
// and implements how a GTK/GLib C signal reaches Swift code. Every other
// file that connects a signal (`PickerWindow+*.swift`, `SettingsWindow+*.swift`)
// reuses `gtkConnect(...)` below rather than repeating this reasoning —
// per this task's own instruction ("Document the pattern you settle on
// once, and reuse it") and coding-standards.md's DRY rule.
//
// THE PROBLEM: `g_signal_connect_data` (like every GLib/GTK signal-connect
// function) takes a `GCallback` — an untyped C function pointer
// (`typedef void (*GCallback) (void);`) — plus a `gpointer user_data` that
// is passed back to the handler on every invocation. Two things make this
// awkward from Swift:
//
//  1. A Swift CLOSURE that captures state (e.g. `{ [weak self] in ... }`)
//     cannot be converted to a C function pointer at all — Swift only
//     allows a non-capturing top-level function/closure to bridge to
//     `@convention(c)`, since a C function pointer has no room for a
//     captured environment. So the "state" a handler needs (typically
//     `self`, the owning `PickerWindow`/`SettingsWindow`) must travel
//     through the `gpointer user_data` parameter instead of a capture.
//
//  2. `GCallback`'s own declared type (`() -> Void`, zero parameters) is a
//     lie every real signal handler ignores — GTK actually invokes it
//     through a per-signal marshaller with that signal's REAL parameter
//     list (e.g. `key-pressed` passes `(controller, keyval, keycode, state,
//     user_data)` and returns `gboolean`). There is no generic, type-safe
//     way to express this in the imported C API; the sanctioned escape
//     hatch — already used elsewhere in this codebase for exactly this
//     class of problem, see project-context.md decision D59's
//     `dlopen`/`dlsym` + `unsafeBitCast` pattern for `ioctl` — is
//     `unsafeBitCast` to/from `GCallback`, paired with a `@convention(c)`
//     Swift value declared with the SIGNAL'S REAL signature. This is safe
//     in practice (not merely "usually works"): every C function pointer
//     representation on every platform this targets (Ubuntu, x86_64/arm64)
//     is a single machine word with an identical calling-convention ABI
//     regardless of its declared Swift parameter types, so a same-size
//     bit-reinterpretation followed by a call through the CORRECT
//     `@convention(c)` type recovers the exact original call shape. GTK/GLib
//     bindings for every non-C language use this same trick under the hood
//     (that is what a "marshaller" is).
//
// THE PATTERN, used by every signal connection in this module:
//
//  1. Declare the handler as a file-scope (or `static`) `let` of EXPLICIT
//     `@convention(c)` function type, with the signal's real parameter
//     list — e.g. `let onSearchChanged: @convention(c)
//     (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { entry, data in
//     ... }`. Declaring the TYPE explicitly (not inferring it) is what
//     makes Swift emit it using the C calling convention in the first
//     place — a closure literal or top-level function reference only
//     becomes a `@convention(c)` value when the compiler can see that's
//     the expected type at the point it's produced; see this file's
//     `unsafeBitCast(_:to:)` call sites for why this must happen BEFORE
//     the bitcast, not folded into one expression.
//  2. Every parameter type in that signature is a Swift type ABI-compatible
//     with its real C type, NOT necessarily the exact name the Clang
//     importer would have picked for it (see `KeyEventMapping.swift`'s top
//     doc comment for the same reasoning applied to `GdkModifierType`):
//     `OpaquePointer?` for any `GObject`-derived pointer (`GtkWidget*`,
//     `GtkListBoxRow*`, `GParamSpec*`, ...), `UnsafeMutableRawPointer?` for
//     a bare `gpointer`, `UInt32` for `guint`/an enum-typed C parameter
//     (`GdkModifierType`, a keyval, ...), `Int32` for `gint`/`gboolean`.
//     This sidesteps ever needing to know the exact (and, per the Clang
//     importer, unstable-to-predict-without-compiling) generated Swift
//     name for a GTK/GDK enum or opaque struct type.
//  3. Recover the Swift instance the handler needs from `user_data` via
//     `unretainedContext(_:as:)` below — never touch `self` through a
//     Swift closure capture.
//  4. Connect via `gtkConnect(...)`, which retains the context object for
//     the lifetime of the connection (`Unmanaged.passRetained`) and
//     supplies `releaseTrampolineContext` as the `GClosureNotify` GTK
//     calls to release it once the signal handler is disconnected/the
//     object is destroyed — so the context is neither leaked (retained
//     forever) nor freed while GTK might still call back into it.
//
// Swift 6 strict concurrency: a `@convention(c)` handler is, by
// construction, NOT isolated to any actor (a bare C function pointer
// cannot carry actor isolation) — it must not itself touch `@MainActor`
// state. Every handler in this module immediately hands off to an
// ordinary (non-`@convention(c)`) instance method on the recovered
// `PickerWindow`/`SettingsWindow`, which uses `MainActor.assumeIsolated`
// to cross back into `PickerViewModel`'s/`SettingsStore`'s isolation — see
// `PickerWindow.swift`'s top doc comment for why that's sound here (a
// single-threaded GLib main loop, the same thread the whole process's
// main-actor work already runs on).
import CGtk4

/// Reinterprets an opaque GObject/widget pointer as the specific
/// GObject-family type a given GTK/GDK call expects (`GtkWindow`,
/// `GtkPopover`, `GtkToggleButton`, `GtkListBoxRow`, ...). Every widget/
/// object handle in this module is stored and passed around as a plain
/// `OpaquePointer` (see `Interop/GTKCallbackTrampoline.swift`'s top doc
/// comment, point 2) since GObject's C "subclass" pointers are all
/// structurally compatible prefixes of their "superclass" — the exact
/// thing C's own `GTK_WINDOW(x)`/`GTK_POPOVER(x)`-style cast macros
/// perform, none of which are imported into Swift (the Clang importer
/// skips function-like macros with a cast body). This is their
/// replacement: safe precisely because the underlying memory really is
/// laid out that way, and used only to call an API whose C signature
/// requires the more specific type.
func gtkPointer<T>(_ pointer: OpaquePointer) -> UnsafeMutablePointer<T> {
  UnsafeMutablePointer<T>(pointer)
}

/// Retains `context` and returns an opaque pointer suitable for a signal
/// connection's `gpointer user_data` — pair with `releaseTrampolineContext`
/// as the connection's `GClosureNotify` so the reference is released
/// exactly once, when GTK tears down the connection.
func retainedTrampolineContext<T: AnyObject>(_ context: T) -> UnsafeMutableRawPointer {
  Unmanaged.passRetained(context).toOpaque()
}

/// Recovers the Swift instance a `@convention(c)` handler was connected
/// with, from its `user_data` pointer. Does not consume/release the
/// reference — a signal fires many times before `releaseTrampolineContext`
/// eventually runs once, at disconnection.
func unretainedContext<T: AnyObject>(_ data: UnsafeMutableRawPointer?, as: T.Type) -> T? {
  guard let data else { return nil }
  return Unmanaged<T>.fromOpaque(data).takeUnretainedValue()
}

/// The `GClosureNotify` (`void (*)(gpointer data, GClosure *closure)`)
/// passed to every `gtkConnect(...)` call — releases the reference
/// `retainedTrampolineContext` created. `GClosure`, unlike most GObject
/// types this module touches, DOES get its own named Swift type (verified
/// empirically against this GTK 4.6 build — see `GTKShims.swift`'s top doc
/// comment for the same kind of per-type verification), so the second
/// parameter is `UnsafeMutablePointer<GClosure>?`, not `OpaquePointer?` —
/// getting this one wrong doesn't produce a clear type-mismatch error at
/// the `unsafeBitCast` (which accepts any same-size type by design) but a
/// baffling "ambiguous without a type annotation" at the UNRELATED-looking
/// `g_signal_connect_data(...)` call site that later passes this value
/// where the real, correctly-typed `GClosureNotify` is expected — worth
/// remembering if a future signal's destroy-notify shape needs the same
/// care.
private let releaseTrampolineContext:
  @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) ->
    Void = { data, _ in
      guard let data else { return }
      Unmanaged<AnyObject>.fromOpaque(data).release()
    }

/// The `GDestroyNotify` (`void (*)(gpointer data)`) shape — used by GLib
/// APIs that own a single `gpointer` context WITHOUT a signal/closure
/// attached to it (e.g. `g_timeout_add_full`'s `notify` parameter), unlike
/// `releaseTrampolineContext` above, which is shaped for
/// `g_signal_connect_data`'s two-parameter `GClosureNotify`. Both release
/// the same way; only the C callback shape differs.
let releaseTrampolineContextSingleArg: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
  guard let data else { return }
  Unmanaged<AnyObject>.fromOpaque(data).release()
}

/// A retained context wrapping a single Swift closure — the common case for
/// a control whose signal has an obvious "current value" GTK exposes via
/// its own getter (`gtk_check_button_get_active`, `gtk_spin_button_
/// get_value_as_int`, ...). Reduces every such control to "connect, read
/// the value off the emitting widget, forward it to `perform`" instead of a
/// bespoke context class per control — see `SettingsWindow+*.swift` for
/// every call site (`PickerWindow+Chips.swift` predates this and still uses
/// its own concrete context types, kept as-is rather than churned for a
/// cosmetic-only refactor).
final class ClosureContext<Value> {
  let perform: (Value) -> Void
  init(_ perform: @escaping (Value) -> Void) {
    self.perform = perform
  }
}

/// Connects `signal` on `object` to `callback`, passing `context` as
/// `user_data` (retained for the connection's lifetime — see this file's
/// top doc comment). `callback` must already be `unsafeBitCast` to
/// `GCallback` by the caller, from a `@convention(c)` value whose real
/// signature matches what `signal` actually invokes.
///
/// - Returns: the handler ID `g_signal_connect_data` reports (unused by
///   every current call site — none of this module's connections are ever
///   individually disconnected before the widget itself is destroyed — but
///   returned rather than discarded so a future caller that DOES need
///   `g_signal_handler_disconnect` doesn't have to change this helper's
///   signature to get it).
@discardableResult
func gtkConnect<Context: AnyObject>(
  _ object: OpaquePointer,
  signal: String,
  context: Context,
  callback: GCallback
) -> UInt {
  // Explicit non-optional target type: `UnsafeMutableRawPointer` has both a
  // non-failable `init(_ other: OpaquePointer)` and a failable
  // `init?(_ other: OpaquePointer?)` — with no target type at the call
  // expression itself, Swift can't tell which one `UnsafeMutableRawPointer
  // (object)` means and reports an ambiguity; this local `let` gives it one.
  let instancePointer: UnsafeMutableRawPointer = UnsafeMutableRawPointer(object)
  return g_signal_connect_data(
    instancePointer,
    signal,
    callback,
    retainedTrampolineContext(context),
    releaseTrampolineContext,
    GConnectFlags(rawValue: 0)
  )
}
