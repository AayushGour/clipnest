import ClipnestCore
import Foundation

/// Shared (macOS + Linux) save logic for editing a copied item: re-derives the
/// content fields exactly as capture would, writes the rich blob, updates the
/// store in place, and re-syncs the system clipboard when it still holds the
/// pre-edit item.
///
/// Threading: only `readClipboardPayload()` and pasteboard writes touch the
/// main actor; hashing, serialization and blob I/O run in
/// `Task.detached(priority: .utility)`.
@MainActor
public final class ItemEditCoordinator {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "ItemEditCoordinator")

  private let clipStore: any ClipStore
  private let blobStore: BlobStore
  private let pasteboard: any PasteboardWriting
  private let pasteboardReader: PasteboardReader
  private let readClipboardPayload: @MainActor () -> PasteboardReader.RawPayload?
  private let suppressOwnPasteboardWrite: @MainActor (Int) -> Void
  private let writeConfirmationTimeout: Duration

  public init(
    clipStore: any ClipStore,
    blobStore: BlobStore,
    pasteboard: any PasteboardWriting,
    pasteboardReader: PasteboardReader,
    readClipboardPayload: @escaping @MainActor () -> PasteboardReader.RawPayload?,
    suppressOwnPasteboardWrite: @escaping @MainActor (Int) -> Void,
    writeConfirmationTimeout: Duration
  ) {
    self.clipStore = clipStore
    self.blobStore = blobStore
    self.pasteboard = pasteboard
    self.pasteboardReader = pasteboardReader
    self.readClipboardPayload = readClipboardPayload
    self.suppressOwnPasteboardWrite = suppressOwnPasteboardWrite
    self.writeConfirmationTimeout = writeConfirmationTimeout
  }

  /// The text (and stored rich blob, if any) the editor should open with. A
  /// rich item whose blob is missing or unreadable falls back to its plain
  /// preview, with no blob and `richContentMissing` set.
  public func loadSource(for item: ClipItem) async -> ItemEditSource {
    // An image's editable text is its recognized text, not its preview label.
    if item.supportsRecognizedTextEdit, let recognized = item.ocrText {
      return ItemEditSource(plainText: recognized, richBlob: nil, richContentMissing: false)
    }
    guard item.kind == .richText else {
      return ItemEditSource(plainText: item.previewText, richBlob: nil, richContentMissing: false)
    }
    guard let blobPath = item.blobPath else {
      return ItemEditSource(plainText: item.previewText, richBlob: nil, richContentMissing: true)
    }
    let blobStore = blobStore
    let blob = await Task.detached(priority: .utility) {
      try? blobStore.read(blobPath: blobPath)
    }.value
    return ItemEditSource(
      plainText: item.previewText, richBlob: blob, richContentMissing: blob == nil)
  }

  public func saveContent(of item: ClipItem, output: EditorOutput) async -> ItemEditOutcome {
    // Main actor: the only clipboard read.
    let payload = readClipboardPayload()
    let reader = pasteboardReader
    let blobStore = blobStore

    let prepared: PreparedEdit
    do {
      prepared = try await Task.detached(priority: .utility) {
        try Self.prepare(
          item: item, output: output, payload: payload, reader: reader, blobStore: blobStore)
      }.value
    } catch {
      Self.logger.error("Edit blob write failed: \(String(describing: error))")
      return .failed(message: ItemEditStrings.saveFailed)
    }

    let result: ClipContentUpdateResult
    do {
      result = try await clipStore.updateContent(item.id, with: prepared.update)
    } catch ClipStoreError.notFound {
      await discardCreatedBlob(of: prepared)
      return .itemNoLongerExists
    } catch {
      await discardCreatedBlob(of: prepared)
      Self.logger.error("Edit store update failed: \(String(describing: error))")
      return .failed(message: ItemEditStrings.saveFailed)
    }

    // Compare against the PRE-edit hash: the clipboard still holds the item
    // iff it matched before we changed anything.
    guard prepared.clipboardHash == item.contentHash else {
      return .saved(result.item, clipboard: .notOnClipboard)
    }
    let sync = await rewriteClipboard(for: result.item, output: output)
    return .saved(result.item, clipboard: sync)
  }

  public func saveRecognizedText(of item: ClipItem, text: String) async -> ItemEditOutcome {
    do {
      try await clipStore.setRecognizedText(item.id, text: text)
    } catch ClipStoreError.notFound {
      return .itemNoLongerExists
    } catch {
      Self.logger.error("Recognized-text update failed: \(String(describing: error))")
      return .failed(message: ItemEditStrings.saveFailed)
    }
    var updated = item
    updated.ocrText = text
    return .saved(updated, clipboard: .notOnClipboard)
  }

  // MARK: - Private

  /// Removes the blob this save created when the store write did not land.
  /// Only a blob this call created: a pre-existing file may be another
  /// item's.
  private func discardCreatedBlob(of prepared: PreparedEdit) async {
    guard prepared.createdBlobPath != nil, let path = prepared.update.blobPath else { return }
    let blobStore = blobStore
    await Task.detached(priority: .utility) { try? blobStore.delete(blobPath: path) }.value
  }

  private enum EditPrepareError: Error { case emptyRichBlob }

  private struct PreparedEdit: Sendable {
    let clipboardHash: String?
    let update: ClipContentUpdate
    /// Non-nil only when this call wrote the blob file.
    let createdBlobPath: String?
  }

  /// Off-main work: classify the clipboard payload, derive the content fields
  /// and write the rich blob.
  private nonisolated static func prepare(
    item: ClipItem, output: EditorOutput, payload: PasteboardReader.RawPayload?,
    reader: PasteboardReader, blobStore: BlobStore
  ) throws -> PreparedEdit {
    let clipboardHash = payload.flatMap { reader.classify($0) }?.contentHash
    let kind = ItemEditKindResolver.resolve(
      originalKind: item.kind, plainText: output.plainText, hasFormatting: output.hasFormatting)
    guard kind != .richText || !output.richBlob.isEmpty else {
      // An empty blob would hash to sha256("") and later merge unrelated items.
      throw EditPrepareError.emptyRichBlob
    }
    guard kind == .richText else {
      let derived = ClipContentDerivation.plainText(output.plainText)
      return PreparedEdit(
        clipboardHash: clipboardHash,
        update: ClipContentUpdate(derived: derived, blobPath: nil),
        createdBlobPath: nil)
    }
    let derived = ClipContentDerivation.richText(
      blob: output.richBlob, plainText: output.plainText)
    let blobPath = BlobStore.blobPath(for: output.richBlob)
    var created: String?
    if !blobStore.contains(blobPath: blobPath) {
      created = try blobStore.write(output.richBlob)
    }
    return PreparedEdit(
      clipboardHash: clipboardHash,
      update: ClipContentUpdate(derived: derived, blobPath: blobPath),
      createdBlobPath: created)
  }

  /// Writes the edited item to the clipboard (same `PasteboardWriting` calls
  /// as `PickerViewModel` copy paths), then waits up to
  /// `writeConfirmationTimeout` for the change count to move.
  ///
  /// Writes `output.plainText` (untrimmed), the exact text the stored
  /// `contentHash` was computed from, not the trimmed `previewText`; otherwise
  /// the next "is it on the clipboard" check would never match.
  private func rewriteClipboard(for item: ClipItem, output: EditorOutput) async
    -> ClipboardSyncResult
  {
    let countBefore = pasteboard.changeCount
    if item.kind == .richText {
      pasteboard.writeRichText(rtf: output.richBlob, plain: output.plainText)
    } else {
      pasteboard.writeString(output.plainText, forType: .string)
    }
    let clock = ContinuousClock()
    let deadline = clock.now + writeConfirmationTimeout
    while pasteboard.changeCount == countBefore {
      if clock.now >= deadline {
        Self.logger.notice(
          "edited clipboard write not confirmed within \(writeConfirmationTimeout)")
        armPredictedSuppression(after: countBefore)
        return .writeUnconfirmed
      }
      do {
        try await Task.sleep(for: PasteDismissOrdering.confirmationPollInterval)
      } catch {
        armPredictedSuppression(after: countBefore)
        return .writeUnconfirmed
      }
    }
    suppressOwnPasteboardWrite(pasteboard.changeCount)
    return .written
  }

  /// A write that was not observed in time may still land later (on Linux the
  /// change count moves asynchronously). If the monitor then re-saw it, it
  /// would bump the edited item to the top of History (or add a new entry), so
  /// suppression is armed anyway. The monitor tracks a single ignored count;
  /// we made exactly one write, so the count it will land on is `countBefore +
  /// 1` (the same prediction `Paster`'s write callback effectively relies on).
  private func armPredictedSuppression(after countBefore: Int) {
    suppressOwnPasteboardWrite(countBefore + 1)
  }
}
