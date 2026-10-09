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
  private let restoreGuardLock = NSLock()
  private var restoreGuard = ClipboardManagerRestoreGuard()
  private let isOwnedByThisProcess: () -> Bool
  private var lastLoggedTargetsSerial: Int?

  /// T-TERMCOPY1: a copy that is dropped must leave a trace. Metadata only —
  /// MIME type names and byte counts, never clipboard content.
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "LinuxPasteboard")

  /// Clipnest's own clipboard writes are skipped and their bytes never
  /// requested — on GNOME the owner answering a byte request is this
  /// process's GTK thread, which is usually the thread asking (see
  /// `GTKClipboardWriting.isOwnedByThisProcess`). Two signals, because one
  /// doesn't work on each backend:
  ///
  /// - Parameter isOwnedByThisProcess: exact ownership where GDK knows it
  ///   (X11), checked before even TARGETS is requested.
  /// - The ownership marker in TARGETS (`isOwnWrite`), for Wayland.
  public init(
    connection: any X11SelectionConnecting = X11ClipboardConnection.shared,
    isOwnedByThisProcess: @escaping () -> Bool = { false }
  ) {
    self.connection = connection
    self.isOwnedByThisProcess = isOwnedByThisProcess
  }

  public var changeCount: Int { connection.changeSerial }

  /// Diagnostic passthrough of `X11SelectionConnecting.selectionOwnerWindowID()`
  /// — see that declaration for why an owner id answers a question
  /// `changeCount` structurally cannot. Metadata only (a window id), never
  /// selection bytes, and deliberately NOT gated on the concealed-marker
  /// check the payload accessors below apply: a window id is not content,
  /// and the whole point of reading it is to identify a selection owner
  /// whose payload this type is (correctly) refusing to read.
  public var selectionOwnerWindowID: UInt64? { connection.selectionOwnerWindowID() }

  /// Reports only `.concealed` (never any other key) the instant a privacy
  /// marker is present — fail-closed, matching `PrivacyMarkerDetector`'s
  /// contract. Otherwise reports the union of every category with a
  /// resolvable representation; `PasteboardReader.pullRawPayload`'s own
  /// sequential `types.contains(...)` checks re-derive the correct
  /// cross-category priority (file → image → rich text → text) from this
  /// union, exactly as it already does on macOS.
  public var availableTypes: [ClipMediaType] {
    guard !isOwnedByThisProcess() else { return [] }
    let serial = connection.changeSerial
    let mimeTypes = connection.currentTargets()
    guard !Self.isOwnWrite(mimeTypes) else {
      logTargets(mimeTypes, serial: serial, outcome: "Clipnest's own write")
      return []
    }
    guard !isConcealed(mimeTypes, serial: serial) else {
      logTargets(mimeTypes, serial: serial, outcome: "concealed")
      return [.concealed]
    }

    var types: [ClipMediaType] = []
    if MimeRepresentationSelector.isAvailable(.file, in: mimeTypes) { types.append(.fileURL) }
    if MimeRepresentationSelector.isAvailable(.image, in: mimeTypes) { types.append(.png) }
    if MimeRepresentationSelector.isAvailable(.richText, in: mimeTypes) { types.append(.rtf) }
    if MimeRepresentationSelector.isAvailable(.text, in: mimeTypes) { types.append(.string) }
    logTargets(
      mimeTypes, serial: serial,
      outcome: types.isEmpty ? "no capturable representation" : "capturable")
    return types
  }

  /// Logs the TARGETS this owner offered, once per clipboard serial
  /// (`availableTypes` runs several times per change). Without this line a
  /// dropped copy gave no way to tell "Clipnest never saw the owner change"
  /// from "it saw targets it could not use" (T-TERMCOPY1).
  private func logTargets(_ mimeTypes: [String], serial: Int, outcome: String) {
    restoreGuardLock.lock()
    let isFirstLogForSerial = lastLoggedTargetsSerial != serial
    lastLoggedTargetsSerial = serial
    restoreGuardLock.unlock()
    guard isFirstLogForSerial else { return }
    let message = "clipboard serial=\(serial) targets=\(mimeTypes) → \(outcome)"
    if mimeTypes.isEmpty || outcome == "capturable" || outcome == "Clipnest's own write" {
      Self.logger.info(message)
    } else {
      Self.logger.notice(message)
    }
  }

  public func string(forType type: ClipMediaType) -> String? {
    guard !isOwnedByThisProcess() else { return nil }
    let serial = connection.changeSerial
    let mimeTypes = connection.currentTargets()
    guard !Self.isOwnWrite(mimeTypes) else { return nil }
    guard !isConcealed(mimeTypes, serial: serial) else { return nil }

    switch type {
    case .fileURL:
      return firstFileURI(mimeTypes: mimeTypes)
    case .string:
      guard let mimeType = MimeRepresentationSelector.winningMimeType(for: .text, in: mimeTypes)
      else { return nil }
      guard let data = connection.payload(forMimeType: mimeType) else {
        Self.logger.notice(
          "text conversion refused or timed out: mime=\(mimeType) serial=\(serial)")
        return nil
      }
      // An owner that answers a text request with zero bytes holds nothing
      // worth keeping; storing it produced a blank history row (seen on real
      // hardware, 2026-10-09). Treated as "no payload" instead.
      guard !data.isEmpty else {
        Self.logger.notice("text conversion returned 0 bytes: mime=\(mimeType) serial=\(serial)")
        return nil
      }
      guard let text = TextPayloadDecoder.decode(data, mimeType: mimeType) else {
        Self.logger.notice(
          "text payload not decodable: mime=\(mimeType) bytes=\(data.count) serial=\(serial)")
        return nil
      }
      return text
    default:
      return nil
    }
  }

  public func data(forType type: ClipMediaType) -> Data? {
    guard !isOwnedByThisProcess() else { return nil }
    let serial = connection.changeSerial
    let mimeTypes = connection.currentTargets()
    guard !Self.isOwnWrite(mimeTypes) else { return nil }
    guard !isConcealed(mimeTypes, serial: serial) else { return nil }

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

  /// `true` while the clipboard holds a write of Clipnest's own — by exact
  /// ownership or by the marker — without ever requesting its bytes.
  public var holdsOwnWrite: Bool {
    isOwnedByThisProcess() || Self.isOwnWrite(connection.currentTargets())
  }

  /// `true` when `mimeTypes` carry the marker every Clipnest write
  /// publishes — see `LinuxClipboardConstants.clipnestOwnedMarkerMimeType`.
  static func isOwnWrite(_ mimeTypes: [String]) -> Bool {
    mimeTypes.contains(LinuxClipboardConstants.clipnestOwnedMarkerMimeType)
  }

  /// The single privacy gate every accessor above shares: the marker check
  /// plus `ClipboardManagerRestoreGuard`'s restore rule — see that type for
  /// the GNOME clipboard-manager leak it closes.
  ///
  /// `serial` must be read BEFORE `mimeTypes` are fetched. If the owner
  /// changes during the fetch, the older serial then gets a verdict from
  /// the newer targets, which fails closed. Read after, a password owner's
  /// serial could be cached as "not concealed" from the previous owner's
  /// targets, and the next accessor would read the password.
  private func isConcealed(_ mimeTypes: [String], serial: Int) -> Bool {
    restoreGuardLock.lock()
    defer { restoreGuardLock.unlock() }
    return restoreGuard.isConcealed(mimeTypes: mimeTypes, serial: serial)
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
