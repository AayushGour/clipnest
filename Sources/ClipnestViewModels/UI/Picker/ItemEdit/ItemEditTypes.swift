import ClipnestCore
import Foundation

/// What an editor is editing.
public enum ItemEditMode: Equatable, Sendable {
  case content(ClipItem)
  case recognizedText(ClipItem)

  /// The editor window/heading title for this mode.
  public var title: String {
    switch self {
    case .content: return ItemEditStrings.editTitle
    case .recognizedText: return ItemEditStrings.editRecognizedTextTitle
    }
  }
}

/// The text (and, for rich items, stored blob) an editor opens with.
public struct ItemEditSource: Sendable, Equatable {
  public let plainText: String
  public let richBlob: Data?
  /// True when the item is `.richText` but its blob is missing or unreadable,
  /// so the editor opens on plain text and saving loses the formatting. Editors
  /// treat this as lossy (drives the "can't be kept" warning).
  public let richContentMissing: Bool

  public init(plainText: String, richBlob: Data?, richContentMissing: Bool) {
    self.plainText = plainText
    self.richBlob = richBlob
    self.richContentMissing = richContentMissing
  }
}

/// What a platform editor hands back to `ItemEditCoordinator.saveContent`.
public struct EditorOutput: Sendable, Equatable {
  public let plainText: String
  public let hasFormatting: Bool
  public let richBlob: Data

  public init(plainText: String, hasFormatting: Bool, richBlob: Data) {
    self.plainText = plainText
    self.hasFormatting = hasFormatting
    self.richBlob = richBlob
  }
}

/// What happened to the system clipboard after a save. Three states on
/// purpose: a write that could not be confirmed is never reported as written.
public enum ClipboardSyncResult: Sendable, Equatable {
  /// The clipboard held something else (or was empty); it was left untouched.
  case notOnClipboard
  /// The clipboard held the pre-edit item, was rewritten, and the write was observed.
  case written
  /// The clipboard was rewritten but the change was not observed in time.
  case writeUnconfirmed
}

public enum ItemEditOutcome: Sendable, Equatable {
  case saved(ClipItem, clipboard: ClipboardSyncResult)
  case itemNoLongerExists
  /// The save failed. The save may have been partially applied (a store error
  /// can arrive after the write committed, e.g. blob cleanup); callers must
  /// refresh the list.
  case failed(message: String)
}
