import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Errors thrown by `Paster`/`EventSynthesizing` for genuine failures.
///
/// Missing Accessibility is deliberately NOT one of these — it's the
/// documented fallback (clipboard-only paste), never a thrown error or a
/// crash. See coding-standards.md's error-handling pattern and its
/// "Accessibility is optional, not required" privacy must.
public enum PasteError: Error, Equatable, Sendable {
  /// The synthesized ⌘V key event(s) could not be created or posted.
  case eventPostFailed

  /// `.image` content whose bytes could not be decoded into a valid image —
  /// thrown before anything is written to the pasteboard.
  case invalidImageData
}

/// Content `Paster` places on the pasteboard (and, if possible, pastes into
/// the previously-frontmost app). `.image` carries image bytes the *caller*
/// already loaded from `BlobStore` (this type has no `BlobStore` dependency
/// itself and stays a pure pasteboard/event-synthesis type — loading bytes is
/// the caller's job, e.g. `PickerViewModel`). `.file` carries the file's
/// `URL` (sourced from `ClipItem.fileReference` by the caller).
public enum PasteContent: Equatable, Sendable {
  case text(String)
  case image(Data)
  case file(URL)
  case richText(rtf: Data, plain: String)
}

/// Abstraction over writing to `NSPasteboard`, injected so `Paster` can be
/// tested without touching the real system pasteboard — see
/// coding-standards.md's testing rules.
public protocol PasteboardWriting: Sendable {
  /// Clears the pasteboard and writes `string` for `type` in one call —
  /// `Paster` never needs to clear without immediately writing.
  func writeString(_ string: String, forType type: NSPasteboard.PasteboardType)

  /// Clears the pasteboard and writes `data` for `type` in one call — mirrors
  /// `writeString(_:forType:)` for binary payloads (e.g. image bytes).
  func writeData(_ data: Data, forType type: NSPasteboard.PasteboardType)

  /// The pasteboard's current change count, read immediately after a write
  /// so the caller can hand it to `ClipboardMonitor.ignore(changeCount:)` —
  /// otherwise the monitor's next poll would recapture Clipnest's own write
  /// as if it were a new external copy. Every Clipnest-originated pasteboard
  /// write (copy-on-select today, a future synthesized paste) goes through
  /// this same `PasteboardWriting` abstraction, so the suppression call site
  /// stays in exactly one place per writer instead of being reimplemented
  /// against `NSPasteboard.general` directly.
  var changeCount: Int { get }

  /// Clears the pasteboard once, then writes BOTH the `.rtf` and `.string`
  /// representations so a paste target picks the richest form it supports.
  func writeRichText(rtf: Data, plain: String)

  /// Clears the pasteboard and writes `url` as a FILE, via
  /// `NSPasteboard.writeObjects` — deliberately not as a single hand-rolled
  /// `.fileURL` string, which is what this used to do.
  ///
  /// `writeObjects([url as NSURL])` puts every representation AppKit
  /// generates for a file URL on the pasteboard at once: the modern
  /// `public.file-url`, the legacy `NSFilenamesPboardType` that plenty of
  /// apps still read, and a real URL object for anything reading typed
  /// pasteboard items. Writing only `public.file-url` meant a paste into an
  /// app that reads any of the other forms silently produced nothing — or
  /// pasted the literal text `file:///…` instead of the file.
  func writeFileURL(_ url: URL)
}

// `PasteboardWriting` refines `Sendable`, but `NSPasteboard` is an AppKit type
// declared in another module, so Swift 6 requires the Sendable conformance be
// spelled out as `@retroactive @unchecked` in a standalone extension. NSPasteboard
// is a thread-safe system singleton, so `@unchecked` is sound here.
// The retroactive conformance is required by the language here, so silence the
// lint rule that would otherwise flag it.
// swift-format-ignore: AvoidRetroactiveConformances
extension NSPasteboard: @retroactive @unchecked Sendable {}

extension NSPasteboard: PasteboardWriting {
  public func writeString(_ string: String, forType type: NSPasteboard.PasteboardType) {
    clearContents()
    setString(string, forType: type)
  }

  public func writeData(_ data: Data, forType type: NSPasteboard.PasteboardType) {
    clearContents()
    setData(data, forType: type)
  }

  public func writeRichText(rtf: Data, plain: String) {
    clearContents()
    setData(rtf, forType: .rtf)
    setString(plain, forType: .string)
  }

  public func writeFileURL(_ url: URL) {
    clearContents()
    // `as NSURL`: `writeObjects` takes `NSPasteboardWriting`, which `NSURL`
    // conforms to and the Swift-native `URL` value type does not.
    writeObjects([url as NSURL])
  }
}

/// Real, `CGEvent`-based `EventSynthesizing` implementation: synthesizes a ⌘V
/// key-down/key-up pair and posts it through the global HID event tap.
///
/// Never exercised by `ClipnestCoreTests` — `PasterTests` uses a mock
/// `EventSynthesizing` instead, per the spec's explicit "no real key events
/// synthesized in CI" requirement.
public struct CGEventSynthesizer: EventSynthesizing {
  /// Virtual keycode for "V" (`kVK_ANSI_V`), from Carbon's `HIToolbox` keycode table.
  private static let vKeyCode: CGKeyCode = 0x09

  public init() {}

  /// Posts a synthetic ⌘V through the global HID event tap
  /// (`CGEvent.post(tap: .cghidEventTap)`) rather than targeting `app`'s pid
  /// directly (`CGEvent.postToPid(_:)`, this type's original implementation) —
  /// pid-targeted posting proved unreliable in practice for delivering a
  /// synthetic keystroke to a previously-frontmost app (macOS's
  /// window-server-level event routing doesn't always honor it the way a
  /// real keystroke injected through the global HID tap is honored).
  /// `app` is accepted for `EventSynthesizing`'s protocol contract (and
  /// still meaningfully asserted on by `PasterTests`' mock, which verifies
  /// `Paster` computes and passes the right target) but is otherwise unused
  /// by this global-post implementation — correctness now depends on the
  /// target app actually holding key focus by the time this posts, which is
  /// exactly why `Paster.paste` waits `synthesisDelay` beforehand.
  public func synthesizeCommandV(targeting app: FrontmostAppRef) throws {
    let source = CGEventSource(stateID: .combinedSessionState)

    guard
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
    else {
      throw PasteError.eventPostFailed
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand

    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
  }
}

/// Writes `PasteContent` to the system pasteboard and, only when Accessibility
/// is granted, synthesizes ⌘V into the previously-frontmost app via an
/// injected `EventSynthesizing`.
///
/// Accessibility-granted state is injected (`isAccessibilityGranted`) instead
/// of calling `AXIsProcessTrusted()` directly, so tests never touch the real
/// permission — see coding-standards.md's testing rules and its
/// "Accessibility is optional, not required" privacy must.
public struct Paster: Sendable {
  /// How long `paste(_:targetingFrontmostApp:)` waits after the pasteboard
  /// write, before posting the synthesized ⌘V, when Accessibility is
  /// granted and a target is available. Exists because
  /// `CGEventSynthesizer` posts through the *global* HID event tap rather
  /// than targeting a specific pid (see that type's doc comment) — the
  /// previously-frontmost app needs a brief moment to actually regain key
  /// focus (the caller is expected to have already hidden Clipnest's own
  /// panel by this point — see `PickerViewModel.pasteAndDismiss`) before a
  /// globally-posted synthetic keystroke is guaranteed to land there
  /// instead of wherever else currently holds focus.
  public static let defaultSynthesisDelay: Duration = .milliseconds(40)

  private let pasteboard: any PasteboardWriting
  private let eventSynthesizer: any EventSynthesizing
  private let isAccessibilityGranted: @Sendable () -> Bool
  private let synthesisDelay: Duration

  public init(
    pasteboard: any PasteboardWriting = NSPasteboard.general,
    eventSynthesizer: any EventSynthesizing = CGEventSynthesizer(),
    isAccessibilityGranted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
    synthesisDelay: Duration = Paster.defaultSynthesisDelay
  ) {
    self.pasteboard = pasteboard
    self.eventSynthesizer = eventSynthesizer
    self.isAccessibilityGranted = isAccessibilityGranted
    self.synthesisDelay = synthesisDelay
  }

  /// Writes `content` to the pasteboard, then — only if Accessibility is
  /// granted and a target app was provided — waits `synthesisDelay` and
  /// synthesizes ⌘V targeting `frontmostApp` (typically
  /// `FrontmostAppTracker.consume()`'s result).
  ///
  /// If Accessibility is not granted, or no target is available, this stops
  /// after the pasteboard write: no error, no crash, no delay — the
  /// documented fallback. `async` solely to allow `synthesisDelay`; the
  /// pasteboard write itself still happens synchronously, before any
  /// suspension point, so a caller reading `pasteboard.changeCount`
  /// immediately after this call returns (to feed
  /// `ClipboardMonitor.ignore(changeCount:)`) still observes the correct
  /// value.
  public func paste(
    _ content: PasteContent,
    targetingFrontmostApp frontmostApp: FrontmostAppRef?
  ) async throws {
    switch content {
    case .text(let string):
      pasteboard.writeString(string, forType: .string)
    case .image(let data):
      // The bytes captured for a clip could be either PNG or TIFF (see
      // `PasteboardReader.imagePasteboardTypes`) — decoding via
      // `NSImage(data:)` then taking `.tiffRepresentation` normalizes to one
      // format under the `.tiff` pasteboard type, which is what virtually
      // every macOS app expects for a pasted image regardless of the
      // original format. No force-unwrap: undecodable bytes throw instead
      // of crashing, per coding-standards.md.
      guard let tiffData = NSImage(data: data)?.tiffRepresentation else {
        throw PasteError.invalidImageData
      }
      pasteboard.writeData(tiffData, forType: .tiff)
    case .file(let url):
      pasteboard.writeFileURL(url)
    case .richText(let rtf, let plain):
      pasteboard.writeRichText(rtf: rtf, plain: plain)
    }

    guard isAccessibilityGranted(), let frontmostApp else { return }

    try? await Task.sleep(for: synthesisDelay)

    try eventSynthesizer.synthesizeCommandV(targeting: frontmostApp)
  }
}
