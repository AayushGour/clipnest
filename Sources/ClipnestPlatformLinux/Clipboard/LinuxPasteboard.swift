import ClipnestCore
import Foundation

/// The Linux `MonitoredPasteboard` conformance — see `ClipnestPlatformLinux`'s
/// task report / `project-context.md` for the research finding this whole
/// module rests on: mutter re-owns the X11 `CLIPBOARD` selection on every
/// `MetaSelection::owner-changed`, including native-Wayland copies, so an
/// X11 client watching that selection via XFixes sees every clipboard
/// change on a GNOME session, Wayland or not, via XWayland — with no Shell
/// extension required.
///
/// Every method here is pure orchestration over the injected
/// `X11SelectionConnecting` seam plus the pure helpers in this directory
/// (`MimeRepresentationSelector`, `PrivacyMarkerDetector`,
/// `GnomeCopiedFilesParser`, `UriListParser`, `TextPayloadDecoder`) — fully
/// unit-testable with a fake connection (`LinuxPasteboardTests`). Only the
/// production default, `X11ClipboardConnection`, is unverifiable without a
/// live X server.
///
/// **Semantic-slot mapping, replacing macOS's real UTI namespace:**
/// `PasteboardReader.pullRawPayload` (unmodified, in `ClipnestCore`, out of
/// this task's scope) only ever asks for four `ClipMediaType` keys —
/// `.fileURL`, `.png`, `.rtf`, `.string`, in that priority order — and, for
/// its rich-text branch, ALSO asks for `.string` unconditionally as a
/// plain-text fallback. This type reports each of those four keys as
/// "available" exactly when `MimeRepresentationSelector` finds a winning
/// MIME type for the matching category. For `.fileURL`/`.png`/`.string`,
/// `data(forType:)`/`string(forType:)` resolve that key by fetching and
/// decoding THAT winning MIME type's real payload, regardless of what the
/// real underlying MIME type actually was (e.g. `image/webp` bytes are
/// still reported under the `.png` key) — safe, since `BlobStore` stores
/// opaque bytes and `PortableImageHeaderProbe`'s dimension probing sniffs
/// the real container format from the bytes themselves, not the key they
/// were requested under.
///
/// `.rtf` is the one exception, fixed by the rich-text fidelity task: a
/// real clipboard owner commonly offers SEVERAL rich representations at
/// once (LibreOffice Writer routinely offers both `text/html` and
/// `text/rtf` for a single copy — verified via `xclip -t TARGETS`, not
/// assumed), and picking only the single highest-priority one to store
/// silently discarded whichever wasn't `text/html`. `data(forType: .rtf)`
/// now fetches EVERY offered rich-text representation (see
/// `richTextBundle(mimeTypes:)`) and packs them into one
/// `LinuxRichTextBundle` — see that type's doc comment for the wire format
/// and for why bundling into the one blob slot `ClipnestCore` has room for
/// (rather than widening its model) is the right fix. `GTKClipboardWriting
/// .writeRichText` (paste side, `ClipnestLinuxAppKit`) unpacks the bundle
/// and republishes every representation under its own real MIME type, so
/// a paste target can pick whichever it supports.
public final class LinuxPasteboard: MonitoredPasteboard, @unchecked Sendable {
  private let connection: any X11SelectionConnecting

  public init(connection: any X11SelectionConnecting = X11ClipboardConnection.shared) {
    self.connection = connection
  }

  public var changeCount: Int { connection.changeSerial }

  /// Reports only `.concealed` (never any other key) the instant a privacy
  /// marker is present — fail-closed, matching `PrivacyMarkerDetector`'s
  /// contract. Otherwise reports the union of every category with a
  /// resolvable representation; `PasteboardReader.pullRawPayload`'s own
  /// sequential `types.contains(...)` checks re-derive the correct
  /// cross-category priority (file → image → rich text → text) from this
  /// union, exactly as it already does on macOS.
  public var availableTypes: [ClipMediaType] {
    let mimeTypes = connection.currentTargets()
    guard !PrivacyMarkerDetector.isConcealed(mimeTypes: mimeTypes) else { return [.concealed] }

    var types: [ClipMediaType] = []
    if MimeRepresentationSelector.isAvailable(.file, in: mimeTypes) { types.append(.fileURL) }
    if MimeRepresentationSelector.isAvailable(.image, in: mimeTypes) { types.append(.png) }
    if MimeRepresentationSelector.isAvailable(.richText, in: mimeTypes) { types.append(.rtf) }
    if MimeRepresentationSelector.isAvailable(.text, in: mimeTypes) { types.append(.string) }
    return types
  }

  public func string(forType type: ClipMediaType) -> String? {
    let mimeTypes = connection.currentTargets()
    guard !PrivacyMarkerDetector.isConcealed(mimeTypes: mimeTypes) else { return nil }

    switch type {
    case .fileURL:
      return firstFileURI(mimeTypes: mimeTypes)
    case .string:
      guard let mimeType = MimeRepresentationSelector.winningMimeType(for: .text, in: mimeTypes),
        let data = connection.payload(forMimeType: mimeType)
      else { return nil }
      return TextPayloadDecoder.decode(data, mimeType: mimeType)
    default:
      return nil
    }
  }

  public func data(forType type: ClipMediaType) -> Data? {
    let mimeTypes = connection.currentTargets()
    guard !PrivacyMarkerDetector.isConcealed(mimeTypes: mimeTypes) else { return nil }

    switch type {
    case .png:
      guard let mimeType = MimeRepresentationSelector.winningMimeType(for: .image, in: mimeTypes)
      else { return nil }
      return connection.payload(forMimeType: mimeType)
    case .rtf:
      return richTextBundle(mimeTypes: mimeTypes)?.encode()
    default:
      return nil
    }
  }

  /// Fetches EVERY rich-text representation the owner actually offers
  /// (not just the highest-priority one) and bundles them into one
  /// `LinuxRichTextBundle` — see that type's doc comment for why bundling
  /// into the single opaque blob slot, rather than widening
  /// `ClipnestCore`'s model, is the fidelity fix. A representation whose
  /// TARGET was advertised but whose payload conversion then fails (a
  /// refused/failed `XConvertSelection`) is simply skipped rather than
  /// aborting the whole capture — strictly more resilient than the old
  /// single-representation path, which returned `nil` outright if its one
  /// chosen MIME type's payload fetch failed even when a lower-priority
  /// candidate would have worked. Returns `nil` only when NONE of the
  /// candidates yield a real payload.
  private func richTextBundle(mimeTypes: [String]) -> LinuxRichTextBundle? {
    let representations = MimeRepresentationSelector.allAvailableMimeTypes(
      for: .richText, in: mimeTypes
    ).compactMap { mimeType -> LinuxRichTextBundle.Representation? in
      guard let payload = connection.payload(forMimeType: mimeType) else { return nil }
      return LinuxRichTextBundle.Representation(mimeType: mimeType, data: payload)
    }
    guard !representations.isEmpty else { return nil }
    return LinuxRichTextBundle(representations: representations)
  }

  /// Resolves the file category's winning MIME type, fetches its payload,
  /// and returns the FIRST file URI it declares — `PasteboardReader
  /// .readFile` only understands a single URL string (mirroring macOS's
  /// own single-`.fileURL`-string pasteboard shape), so a multi-file
  /// GNOME/URI-list copy captures its first file only. Widening
  /// `ClipnestCore` to a multi-file `ClipItem` is out of this task's scope
  /// (it owns none of `Sources/ClipnestCore`) — flagged here, not silently
  /// dropped.
  private func firstFileURI(mimeTypes: [String]) -> String? {
    guard let mimeType = MimeRepresentationSelector.winningMimeType(for: .file, in: mimeTypes),
      let data = connection.payload(forMimeType: mimeType),
      let text = String(data: data, encoding: .utf8)
    else { return nil }

    switch mimeType {
    case LinuxClipboardConstants.gnomeCopiedFilesMimeType:
      return GnomeCopiedFilesParser.parse(text)?.fileURIs.first
    default:  // LinuxClipboardConstants.uriListMimeType
      return UriListParser.parse(text).first
    }
  }
}
