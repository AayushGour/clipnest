// StoreOpenFailureRecovery.swift
//
// T-STOREALERT1: pure, AppKit-free decision logic behind the "Clipnest couldn't
// open its history database" alert. `AppDelegate` used to log a fault and
// terminate silently when `AppEnvironment()` threw (the menu-bar icon just
// vanished). The alert itself is a thin AppKit shell (`StoreOpenFailureAlert`
// in the app target); everything testable lives here.
//
// `ModelContainerRecovery` already moves a corrupt store aside and retries once
// per store, so an error only reaches this point when that retry also failed
// (or the failure is not store corruption, e.g. a read-only directory). The
// error does not say WHICH store failed, so a reset moves BOTH stores aside
// and the alert text says so. Nothing is ever deleted: files are moved into a
// timestamped backup folder next to them. Attachment blobs (`Blobs/`) are left
// untouched.

import ClipnestCore
import Foundation

public enum StoreOpenFailureRecovery {
  /// On-disk store file names: the stores' own constants on macOS (the only
  /// platform with SwiftData stores). Linux uses SQLite stores, which never
  /// hit this alert path, so the names are only a compile-time placeholder
  /// there (same values; `StoreOpenFailureRecoveryTests` pins them on macOS).
  #if os(macOS)
    public static let clipStoreFileName = SwiftDataClipStore.storeFileName
    public static let snippetStoreFileName = SwiftDataSnippetStore.storeFileName
  #else
    public static let clipStoreFileName = "ClipItems.store"
    public static let snippetStoreFileName = "Snippets.store"
  #endif
  /// SQLite sidecar suffixes moved together with each store file.
  public static let sidecarSuffixes = ["-wal", "-shm"]
  /// Prefix of the backup folder; the timestamp (ms since epoch) is appended.
  public static let backupFolderPrefix = "Reset-Backup-"

  /// Alert copy.
  public static let alertTitle = "Clipnest couldn't open its history"
  public static let resetButtonTitle = "Reset History…"
  public static let showInFinderButtonTitle = "Show in Finder"
  public static let quitButtonTitle = "Quit"
  public static let cancelButtonTitle = "Cancel"
  public static let confirmTitle = "Reset clipboard history and snippets?"
  public static let confirmResetButtonTitle = "Reset"
  public static let finalFailureTitle = "Clipnest still can't start"

  public enum Choice: Equatable, Sendable {
    case resetHistory
    case showInFinder
    case quit
  }

  /// Metadata-only error summary (type + NSError domain/code); never the
  /// message text, which could in principle echo store contents.
  public static func summary(for error: Error) -> String {
    let error = (error as? PartialMoveError)?.underlying ?? error
    let ns = error as NSError
    return "\(type(of: error)) (\(ns.domain) \(ns.code))"
  }

  public static func alertMessage(errorSummary: String) -> String {
    """
    Clipnest could not open its history database, so it can't run. Your \
    clipboard history is not deleted.

    Error: \(errorSummary)

    You can reset the history to start fresh. This sets aside BOTH your \
    clipboard history and your snippets (the failing store can't be \
    identified) into a backup folder in the Clipnest data folder; nothing is \
    deleted.
    """
  }

  public static func confirmMessage() -> String {
    """
    Your clipboard history AND snippets will be moved into a backup folder \
    inside the Clipnest data folder, and Clipnest will start with both empty. \
    Nothing is deleted; you can restore from the backup folder later.
    """
  }

  public static func finalFailureMessage(errorSummary: String, backupFolder: URL?) -> String {
    var text = "Clipnest still couldn't start after the reset.\n\nError: \(errorSummary)"
    if let backupFolder {
      text += "\n\nYour previous data was kept in \(backupFolder.lastPathComponent)."
    }
    return text
  }

  /// Thrown by `moveStoresAside` when a move fails after the backup folder
  /// was created, so the caller still learns where already-moved files are.
  public struct PartialMoveError: Error {
    public let backupFolder: URL
    public let underlying: Error
  }

  /// The backup folder to mention in the failure alert: the explicitly known
  /// one, else the one carried by a `PartialMoveError`.
  public static func backupFolder(from error: Error, known: URL?) -> URL? {
    known ?? (error as? PartialMoveError)?.backupFolder
  }

  /// Files that make up the stores (store + sidecars), in `directory`.
  static func storeFileURLs(in directory: URL) -> [URL] {
    [clipStoreFileName, snippetStoreFileName].flatMap { name -> [URL] in
      ([""] + sidecarSuffixes).map { directory.appendingPathComponent(name + $0) }
    }
  }

  /// Moves every existing store file into a new timestamped folder inside
  /// `directory`. Returns the backup folder (nil when there was nothing to
  /// move). Never deletes. The folder is created owner-only (0700). Throws the
  /// raw error if the folder can't be created, or `PartialMoveError` (carrying
  /// the folder) if a move fails after it exists.
  @discardableResult
  public static func moveStoresAside(
    in directory: URL,
    fileManager: FileManager = .default,
    now: Date = Date()
  ) throws -> URL? {
    let existing = storeFileURLs(in: directory).filter {
      fileManager.fileExists(atPath: $0.path)
    }
    guard !existing.isEmpty else { return nil }
    let stamp = Int(now.timeIntervalSince1970 * 1_000)
    let backup = directory.appendingPathComponent(
      "\(backupFolderPrefix)\(stamp)", isDirectory: true)
    try PrivateDataPermissions.secureDirectory(backup, fileManager: fileManager)
    do {
      for url in existing {
        try fileManager.moveItem(
          at: url, to: backup.appendingPathComponent(url.lastPathComponent))
      }
    } catch {
      throw PartialMoveError(backupFolder: backup, underlying: error)
    }
    return backup
  }
}
