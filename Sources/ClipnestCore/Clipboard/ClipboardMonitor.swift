import AppKit
import Foundation
import os

/// Abstraction over "what app is currently frontmost," used to attribute a
/// captured clip to its source app and to feed `PrivacyFilter.shouldCapture`'s
/// `sourceBundleID` check.
///
/// Deliberately separate from `Paste/FrontmostAppTracker` (plan task T14), which
/// records the frontmost app at a different point in time — right before the
/// picker opens — for a different purpose (paste targeting).
public protocol FrontmostApplicationProviding: Sendable {
  var frontmostBundleID: String? { get }
  var frontmostAppName: String? { get }
}

/// Production `FrontmostApplicationProviding` backed by `NSWorkspace`.
public struct WorkspaceFrontmostApplicationProvider: FrontmostApplicationProviding {
  public init() {}

  public var frontmostBundleID: String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
  }

  public var frontmostAppName: String? {
    NSWorkspace.shared.frontmostApplication?.localizedName
  }
}

/// Combines pasteboard-content reading (`PasteboardReading`) with change-count
/// polling, so a single injected value — `NSPasteboard.general` in production, a
/// fake in tests — can serve both roles for `ClipboardMonitor`.
public protocol MonitoredPasteboard: PasteboardReading {
  var changeCount: Int { get }
}

extension NSPasteboard: MonitoredPasteboard {}

/// Reports a `ClipStore` failure encountered while trying to store a capture.
///
/// `checkNow()` calls this instead of silently discarding the error (see
/// coding-standards.md: "do not swallow errors silently") so a real store
/// failure is distinguishable from "nothing to capture this cycle." Receives
/// only the thrown error — never the clipboard content that triggered it.
public typealias CaptureFailureHandler = @Sendable (Error) -> Void

/// Polls the pasteboard's `changeCount` for changes and, when one passes
/// `PrivacyFilter`, reads it via `PasteboardReader` and stores it via `ClipStore`.
///
/// Tests drive capture deterministically through `checkNow()` instead of waiting
/// on a real `Timer` — see `.claude/coding-standards.md`'s testing rules (no real
/// timers, no real key events in `ClipnestCoreTests`).
@MainActor
public final class ClipboardMonitor {
  /// Default poll interval, per the spec: macOS has no push notification for
  /// pasteboard changes, so ~0.4s balances responsiveness against CPU wake-ups.
  public static let defaultPollInterval: TimeInterval = 0.4

  private nonisolated static let logger = Logger(
    subsystem: "com.clipnest.app", category: "ClipboardMonitor")

  /// Default `CaptureFailureHandler`: logs metadata only (the error case name)
  /// via `os.Logger` — never the clipboard content that triggered the attempt.
  ///
  /// `nonisolated` + `public` because it's used as a default value on the
  /// `public` initializer below, which requires matching accessibility and no
  /// actor isolation (it touches no instance state, only the static `logger`).
  public nonisolated static func logCaptureFailure(_ error: Error) {
    let reason: String
    switch error {
    case let clipStoreError as ClipStoreError:
      switch clipStoreError {
      case .notFound: reason = "notFound"
      case .ioFailure: reason = "ioFailure"
      }
    case is BlobStoreError:
      reason = "blobIOFailure"
    default:
      reason = String(describing: type(of: error))
    }
    logger.error(
      "ClipboardMonitor: failed to persist a captured item (\(reason, privacy: .public))")
  }

  private let store: any ClipStore
  private let privacyFilter: PrivacyFilter
  private let reader: PasteboardReader
  private let blobStore: BlobStore
  private let pasteboard: any MonitoredPasteboard
  private let frontmostApplicationProvider: any FrontmostApplicationProviding
  private let pollInterval: TimeInterval
  private let excludedBundleIDsProvider: @Sendable () -> Set<String>
  private let captureFailureHandler: CaptureFailureHandler

  private var timer: Timer?
  private var lastChangeCount: Int

  /// A pasteboard `changeCount` that Clipnest itself produced (via
  /// `ignore(changeCount:)`) and that `checkNow()` should treat as
  /// already-seen instead of a new external copy. `nil` when nothing is
  /// pending. See `ignore(changeCount:)`'s doc comment.
  private var ignoredChangeCount: Int?

  /// Whether capture is currently paused. Honored by `checkNow()`; wired to
  /// UI (menu + Settings) in plan task T31.
  public private(set) var isPaused = false

  /// Called on `@MainActor` right after `checkNow()` successfully stores a
  /// captured item — a fresh insert or a dedup bump (see
  /// `insertOrBumpDuplicate`'s doc comment; a bump also updates `createdAt`
  /// to now, so it belongs at the top of History again too). Lets the
  /// composition root (`AppEnvironment`, which owns both this monitor and
  /// `PickerViewModel`) push a live update into the picker instead of the
  /// picker polling `ClipStore` on a timer (plan task T50/T51 — see
  /// `PickerViewModel`'s doc comment). Defaults to a no-op so this type
  /// stays usable without a listener (e.g. in isolated tests). Not
  /// `@Sendable`/optional-closure-crossing-actors: `ClipboardMonitor` is
  /// itself `@MainActor`, so a plain stored closure is safe here, mirroring
  /// `PickerViewModel.dismiss`/`suppressOwnPasteboardWrite`'s identical
  /// "settable after construction, defaults to a no-op" shape.
  public var onCapture: (ClipItem) -> Void = { _ in }

  public init(
    store: any ClipStore,
    privacyFilter: PrivacyFilter = PrivacyFilter(),
    reader: PasteboardReader = PasteboardReader(),
    blobStore: BlobStore = BlobStore(baseDirectory: BlobStore.defaultBaseDirectory()),
    pasteboard: any MonitoredPasteboard = NSPasteboard.general,
    frontmostApplicationProvider: any FrontmostApplicationProviding =
      WorkspaceFrontmostApplicationProvider(),
    pollInterval: TimeInterval = ClipboardMonitor.defaultPollInterval,
    excludedBundleIDsProvider: @escaping @Sendable () -> Set<String> = { [] },
    captureFailureHandler: @escaping CaptureFailureHandler = ClipboardMonitor.logCaptureFailure
  ) {
    self.store = store
    self.privacyFilter = privacyFilter
    self.reader = reader
    self.blobStore = blobStore
    self.pasteboard = pasteboard
    self.frontmostApplicationProvider = frontmostApplicationProvider
    self.pollInterval = pollInterval
    self.excludedBundleIDsProvider = excludedBundleIDsProvider
    self.captureFailureHandler = captureFailureHandler
    lastChangeCount = pasteboard.changeCount
  }

  /// Starts polling on a repeating `Timer`. No-op if already started.
  public func start() {
    guard timer == nil else { return }
    let newTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
      [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        _ = await self.checkNow()
      }
    }
    timer = newTimer
  }

  /// Stops polling. Safe to call even if not started.
  public func stop() {
    timer?.invalidate()
    timer = nil
  }

  /// Pauses capture. `checkNow()` still advances `lastChangeCount` so that
  /// resuming doesn't immediately re-capture whatever changed while paused.
  public func pause() {
    isPaused = true
  }

  /// Resumes capture after `pause()`.
  public func resume() {
    isPaused = false
  }

  /// Tells the monitor that `changeCount` is the result of a pasteboard
  /// write Clipnest itself performed — a copy-on-select in the picker
  /// (plan task T12), or a future synthesized paste (`Paster`, plan task
  /// T15/T16) — not a real external copy. Any caller that writes to the
  /// pasteboard Clipnest itself owns should call this immediately after,
  /// with the pasteboard's resulting `changeCount`.
  ///
  /// The next `checkNow()` that observes exactly this `changeCount` treats
  /// it as already-seen: `lastChangeCount` still advances past it (so it's
  /// never re-evaluated), but nothing is classified or stored. A change to
  /// any *other* `changeCount` (a real external copy) is unaffected.
  ///
  /// Only one ignored `changeCount` is tracked at a time — a later call
  /// before the pending one is consumed overwrites it, mirroring
  /// `FrontmostAppTracker`'s "last-recorded wins" semantics.
  public func ignore(changeCount: Int) {
    ignoredChangeCount = changeCount
  }

  /// Performs one check-and-capture cycle synchronously with respect to test
  /// control flow: reads the pasteboard's current `changeCount`, and if it
  /// differs from the last observed value, classifies and (if accepted by
  /// `PrivacyFilter`) stores the content. Returns the resulting stored item,
  /// or `nil` if nothing was captured this cycle.
  @discardableResult
  public func checkNow() async -> ClipItem? {
    let currentChangeCount = pasteboard.changeCount
    guard currentChangeCount != lastChangeCount else { return nil }
    lastChangeCount = currentChangeCount

    if ignoredChangeCount == currentChangeCount {
      ignoredChangeCount = nil
      return nil
    }

    let sourceBundleID = frontmostApplicationProvider.frontmostBundleID
    let sourceAppName = frontmostApplicationProvider.frontmostAppName

    guard
      privacyFilter.shouldCapture(
        availableTypes: pasteboard.availableTypes,
        sourceBundleID: sourceBundleID,
        isPaused: isPaused,
        customExcludedBundleIDs: excludedBundleIDsProvider()
      )
    else {
      return nil
    }

    guard let result = reader.read(from: pasteboard) else { return nil }

    let blobPath: String?
    do {
      if let rawData = result.rawData {
        // Off the main actor: `BlobStore` is `Sendable` and `write(_:)` is
        // pure filesystem I/O, so a large payload's disk write can't block
        // the UI here — same `Task.detached(priority: .utility)` pattern
        // already used for off-main blob reads (`ItemPreview.AsyncBlobImage`,
        // `ItemRow.load()`). Copied into a local `let` first so the closure
        // captures the `Sendable` `BlobStore` value, not `self`.
        let blobStore = self.blobStore
        blobPath = try await Task.detached(priority: .utility) {
          try blobStore.write(rawData)
        }.value
      } else {
        blobPath = nil
      }
    } catch {
      // A blob write failure means this capture cannot be safely stored
      // (a dangling blobPath is worse than not capturing this cycle) — same
      // "surface, don't swallow" pattern as a `ClipStore` failure below.
      captureFailureHandler(error)
      return nil
    }

    // Only `.file` classifications ever carry `fileURL` — gated explicitly
    // (not just relying on `result.fileURL` being nil for other kinds) so
    // `.image`/`.text`/`.link`/`.richText` items are never affected by this.
    let fileReference: String? = result.kind == .file ? result.fileURL?.absoluteString : nil

    let item = ClipItem(
      kind: result.kind,
      previewText: result.previewText,
      contentHash: result.contentHash,
      sourceAppName: sourceAppName,
      sourceBundleID: sourceBundleID,
      byteSize: result.byteSize,
      blobPath: blobPath,
      fileReference: fileReference
    )

    do {
      let stored = try await store.insertOrBumpDuplicate(item)
      onCapture(stored)
      return stored
    } catch {
      // Surface the failure (metadata-only) instead of silently returning nil
      // for both "nothing to capture" and "the store failed" — see
      // coding-standards.md's error-handling rule.
      captureFailureHandler(error)
      return nil
    }
  }
}
