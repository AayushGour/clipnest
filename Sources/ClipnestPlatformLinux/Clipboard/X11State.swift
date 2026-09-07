import CXlib
import Foundation

/// The raw bytes of one `XGetWindowProperty` read, together with the
/// server-reported type/format needed to interpret them (format-32
/// properties use native-word-sized items — see
/// `X11ClipboardConnection.words(from:)`).
struct RawX11Property {
  let type: Atom
  let format: Int32
  let bytes: [UInt8]
}

/// Owns the one live Xlib `Display*` connection, the backend's own
/// `InputOnly` watcher window, and every atom this module needs — see
/// `X11ClipboardConnection`'s doc comment for the concurrency model this
/// participates in. Failable: `nil` whenever no X server was reachable
/// (`init` cannot run any Xlib call after that point, so every field below
/// is guaranteed valid once construction succeeds).
///
/// **UNVERIFIABLE WITHOUT A LIVE X SERVER** — see `X11ClipboardConnection`'s
/// doc comment.
final class X11State: @unchecked Sendable {
  let display: OpaquePointer
  let root: Window
  let watcherWindow: Window
  let clipboardAtom: Atom
  let replyPropertyAtom: Atom
  let incrAtom: Atom
  let xfixesSelectionNotifyEventType: Int32
  let connectionFileDescriptor: Int32

  /// A Swift-typed zero, used everywhere Xlib's `None`/`CurrentTime`/
  /// `AnyPropertyType` macros (all literally `0`) are needed — sidesteps
  /// relying on those macros' ClangImporter-inferred integer type
  /// matching whatever a given parameter actually expects.
  static let zero: Atom = 0

  private let atomLock = NSLock()
  private var atomByName: [String: Atom] = [:]
  private var nameByAtom: [Atom: String] = [:]

  init?() {
    // Installed before any other Xlib call: Xlib's DEFAULT error handler
    // calls exit() on an unhandled X protocol error, which would
    // otherwise crash this entire process on a single racy BadWindow —
    // e.g. querying a window's properties right as it closes, an
    // inherently racy operation this backend performs constantly.
    _ = XSetErrorHandler { _, _ in 0 }

    guard let display = XOpenDisplay(nil) else { return nil }

    var eventBase: Int32 = 0
    var errorBase: Int32 = 0
    guard XFixesQueryExtension(display, &eventBase, &errorBase) != 0 else {
      XCloseDisplay(display)
      return nil
    }

    let root = XDefaultRootWindow(display)

    var attributes = XSetWindowAttributes()
    attributes.event_mask = PropertyChangeMask
    let watcherWindow = XCreateWindow(
      display, root, 0, 0, 1, 1, 0, 0, UInt32(InputOnly), nil, UInt(CWEventMask), &attributes)
    guard watcherWindow != 0 else {
      XCloseDisplay(display)
      return nil
    }

    self.display = display
    self.root = root
    self.watcherWindow = watcherWindow
    self.connectionFileDescriptor = XConnectionNumber(display)
    self.xfixesSelectionNotifyEventType = eventBase + Int32(XFixesSelectionNotify)
    self.clipboardAtom = XInternAtom(
      display, LinuxClipboardConstants.clipboardSelectionAtomName, 0)
    self.replyPropertyAtom = XInternAtom(
      display, LinuxClipboardConstants.selectionReplyPropertyAtomName, 0)
    self.incrAtom = XInternAtom(display, LinuxClipboardConstants.incrAtomName, 0)

    let selectionEventMask =
      XFixesSetSelectionOwnerNotifyMask | XFixesSelectionWindowDestroyNotifyMask
      | XFixesSelectionClientCloseNotifyMask
    XFixesSelectSelectionInput(display, watcherWindow, clipboardAtom, UInt(selectionEventMask))
    XFlush(display)
  }

  /// Interns (or returns the cached id for) the atom named `name`.
  func internedAtom(_ name: String) -> Atom {
    atomLock.lock()
    defer { atomLock.unlock() }
    if let cached = atomByName[name] { return cached }
    let atom = XInternAtom(display, name, 0)
    atomByName[name] = atom
    nameByAtom[atom] = name
    return atom
  }

  /// Resolves an atom id back to its name (`XGetAtomName`), cached after
  /// the first lookup.
  func atomName(for atom: Atom) -> String? {
    atomLock.lock()
    if let cached = nameByAtom[atom] {
      atomLock.unlock()
      return cached
    }
    atomLock.unlock()

    guard let cName = XGetAtomName(display, atom) else { return nil }
    defer { _ = XFree(cName) }
    let name = String(cString: cName)

    atomLock.lock()
    nameByAtom[atom] = name
    atomLock.unlock()
    return name
  }

  /// Reads `propertyName` on `window` without deleting it — used for the
  /// one-shot EWMH/ICCCM identity property reads
  /// (`X11ClipboardConnection`'s `X11WindowIdentityQuerying` conformance),
  /// which need no ICCCM property-transfer protocol (no `SelectionNotify`
  /// correlation, no INCR).
  func readProperty(window: Window, propertyName: String) -> RawX11Property? {
    readProperty(window: window, propertyAtom: internedAtom(propertyName), delete: false)
  }

  /// Reads `propertyAtom` on `window` AND deletes it in the same request —
  /// the ICCCM 2.7.2 "delete to acknowledge" step, for both a plain
  /// selection-conversion reply and each successive INCR chunk.
  func readAndDeleteProperty(window: Window, propertyAtom: Atom) -> RawX11Property? {
    readProperty(window: window, propertyAtom: propertyAtom, delete: true)
  }

  private func readProperty(window: Window, propertyAtom: Atom, delete: Bool) -> RawX11Property? {
    var actualType: Atom = 0
    var actualFormat: Int32 = 0
    var itemCount: UInt = 0
    var bytesAfter: UInt = 0
    var propertyData: UnsafeMutablePointer<UInt8>?

    // Requesting type `AnyPropertyType` (`Self.zero`) accepts whatever
    // type the property actually holds — this backend inspects
    // `actualType`/`actualFormat` dynamically rather than asserting one
    // upfront, since the same call site serves every property type this
    // module reads (STRING/UTF8_STRING/CARDINAL/WINDOW/ATOM[]/INCR).
    let status = XGetWindowProperty(
      display, window, propertyAtom, 0, Int(Int32.max), delete ? 1 : 0, Self.zero,
      &actualType, &actualFormat, &itemCount, &bytesAfter, &propertyData)

    guard status == 0, let propertyData else {
      if let propertyData { _ = XFree(propertyData) }
      return nil
    }
    defer { _ = XFree(propertyData) }

    // `XGetWindowProperty` is documented to return `Success` (not an
    // error `status`) even when `propertyAtom` does not exist at all on
    // `window` — it signals that via `actualType == None` (`Self.zero`),
    // not via `status`. Every caller here relies on `nil` meaning
    // "nothing to read" (a claimed-successful ICCCM selection conversion
    // whose reply property was never actually written — see this
    // codebase's P0 clipnest-crash investigation, where GTK4's OWN
    // GdkX11Clipboard hits exactly this "property claims to exist but
    // doesn't" case and, lacking this same guard, dereferences a NULL
    // atom name in `g_str_equal` — a genuine, upstream GTK 4.6.x bug,
    // fixed later by switching to the NULL-safe `g_strcmp0`, that lives
    // entirely inside `libgtk-4.so`/`libgio-2.0.so` and cannot be patched
    // from this module; see `X11ClipboardConnection`'s doc comment).
    // Folding this into the `guard` above would be wrong: a real,
    // *present* property legitimately reports zero items (format 8/16/32
    // is irrelevant, `actualType` is never `None` for it) — ICCCM
    // 2.7.2's zero-length INCR terminator is exactly that case, and must
    // still resolve to a present-but-empty `RawX11Property`, not `nil`.
    guard actualType != Self.zero else { return nil }

    guard itemCount > 0 else {
      return RawX11Property(type: actualType, format: actualFormat, bytes: [])
    }

    // Format 8 = 1 byte/item, format 16 = 2 bytes/item, format 32 = one
    // native machine word (`sizeof(long)`, 8 bytes on a 64-bit Linux
    // host) per item, NOT 4 bytes — a well-documented Xlib quirk in how
    // `prop_return` packs 32-bit protocol values. See
    // `X11ClipboardConnection.words(from:)`, which un-packs this same
    // convention on the read side.
    let bytesPerItem: Int
    switch actualFormat {
    case 32: bytesPerItem = MemoryLayout<UInt>.size
    case 16: bytesPerItem = 2
    default: bytesPerItem = 1
    }

    let byteCount = Int(itemCount) * bytesPerItem
    let bytes = Array(UnsafeBufferPointer(start: propertyData, count: byteCount))
    return RawX11Property(type: actualType, format: actualFormat, bytes: bytes)
  }
}
