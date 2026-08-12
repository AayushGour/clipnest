// AppEnvironment.swift
//
// Clipnest's app composition root: builds and owns the single, shared graph
// of `ClipnestCore` services + the picker UI, and hands them out by
// injection. Nothing here is a global/singleton — `AppDelegate` builds
// exactly one `AppEnvironment` on launch and every consumer (the picker,
// later Settings) receives its dependencies from this one owned graph.
//
// The one wiring rule this exists to enforce: `clipStore` and
// `clipboardMonitor` MUST share the *same* `BlobStore` instance. Both types
// have their own default `BlobStore` constructor parameter for convenience
// in isolated unit tests, but relying on those defaults here would silently
// give each its own `BlobStore` pointed at the same directory — two
// independent instances that happen to agree on paths today, but are one
// refactor away from drifting apart. Constructing exactly one `BlobStore`
// and passing it to both explicitly removes that risk entirely.
//
// Persistence (plan task T40, project-context.md decision D6): the
// production graph is wired to `SwiftDataClipStore`/`SwiftDataSnippetStore`
// — real on-disk persistence via SwiftData, confined behind the same
// `ClipStore`/`SnippetStore` protocols `InMemoryClipStore`/
// `InMemorySnippetStore` implement (those remain the canonical stores for
// `ClipnestCoreTests`, unchanged). `PickerViewModel`/`ClipboardMonitor` both
// depend on `any ClipStore`, so this swap is invisible to them.
//
// Plan task T16: also wires the real paste engine. `frontmostAppTracker`
// is recorded here, in `showPicker()`, right before the panel is shown —
// the one choke point both trigger paths (the global hotkey and the menu
// bar's "Open Clipnest") already share via `AppDelegate.showPicker()` — so
// neither trigger path needs its own record() call. `paster`'s
// `isAccessibilityGranted` is fed the real `PermissionsManager.isGranted`
// (itself a thin wrapper over `AXIsProcessTrusted()`), so the picker's
// select action performs a real synthesized ⌘V when Accessibility is
// granted and falls back to clipboard-only when it isn't.
//
// T23 fix round: owns the one `SnippetEditorWindow` instance too, wiring
// `PickerViewModel.presentSnippetEditor` directly to it — see that window
// type's doc comment for why the snippet editor needed its own key-capable
// `NSWindow` instead of a `.sheet()` on the non-activating `PickerPanel`.
//
// Task 12 (item preview): also owns the one `ItemPreviewController`,
// wiring `PickerViewModel.updatePreview` to its `update(...)` — the
// preview panel it manages must never take key focus (same non-activating
// requirement `PickerPanel` itself has, D11), so `panel.frame` is passed
// through purely as a coarse screen-space anchor rect, never as a focus
// relationship. `panel.onDidHide` also explicitly hides the preview
// alongside `viewModel.didHide()`, so it can't outlive the picker itself.

import AppKit
import ClipnestCore
import Foundation

@MainActor
final class AppEnvironment {
  let blobStore: BlobStore
  let clipStore: SwiftDataClipStore
  let snippetStore: SwiftDataSnippetStore
  let privacyFilter: PrivacyFilter
  let pasteboardReader: PasteboardReader
  let clipboardMonitor: ClipboardMonitor
  let paster: Paster
  let frontmostAppTracker: FrontmostAppTracker
  let pickerViewModel: PickerViewModel
  let pickerPanel: PickerPanel
  let snippetEditorWindow: SnippetEditorWindow
  let snippetExpander: SnippetExpander
  let itemPreviewController: ItemPreviewController

  /// - Throws: whatever `SwiftDataClipStore`/`SwiftDataSnippetStore`'s
  ///   production `ModelContainer` construction throws (typed
  ///   `ClipStoreError`/`SnippetStoreError.ioFailure`) — e.g. the on-disk
  ///   store file can't be created/opened. There's no safe in-app fallback
  ///   from "persistence didn't come up," so this is surfaced to the caller
  ///   (`AppDelegate`) rather than silently degrading to a store the user
  ///   didn't ask for.
  init() throws {
    // One shared BlobStore instance — see the file's doc comment.
    let blobStore = BlobStore(baseDirectory: BlobStore.defaultBaseDirectory())
    let privacyFilter = PrivacyFilter()
    let pasteboardReader = PasteboardReader()
    let clipStore = SwiftDataClipStore(
      modelContainer: try SwiftDataClipStore.makeProductionContainer(), blobStore: blobStore)

    self.blobStore = blobStore
    self.privacyFilter = privacyFilter
    self.pasteboardReader = pasteboardReader
    self.clipStore = clipStore
    let snippetStore = SwiftDataSnippetStore(
      modelContainer: try SwiftDataSnippetStore.makeProductionContainer())
    self.snippetStore = snippetStore

    // T9 (snippet keyword expansion): the concrete AX-backed
    // `SelectedTextAccessing` (`AXSelectedTextAccessor`) and the universal
    // clipboard fallback (`ClipboardSelectionReplacer`) are app-side, so they
    // must be passed explicitly here — `SnippetExpander`'s initializer has no
    // defaults for them because `ClipnestCore` can't reference app-only types.
    // The replacer's capture-suppression closures are wired to the monitor
    // below (once it exists). See `SnippetExpander`'s doc comment.
    let clipboardReplacer = ClipboardSelectionReplacer()
    self.snippetExpander = SnippetExpander(
      snippetStore: snippetStore,
      selectedText: AXSelectedTextAccessor(),
      clipboardReplacer: clipboardReplacer)

    self.clipboardMonitor = ClipboardMonitor(
      store: clipStore,
      privacyFilter: privacyFilter,
      reader: pasteboardReader,
      blobStore: blobStore
    )

    // T16: real paste engine — see this file's doc comment. Feeds the
    // *prompting* Accessibility check (paste-reliability fix) so a paste
    // attempt without Accessibility granted surfaces the system "grant
    // access" dialog instead of silently degrading with no explanation.
    let paster = Paster(
      isAccessibilityGranted: { PermissionsManager.isGrantedPromptingIfNeeded() }
    )
    self.paster = paster
    let frontmostAppTracker = FrontmostAppTracker()
    self.frontmostAppTracker = frontmostAppTracker

    let viewModel = PickerViewModel(
      clipStore: clipStore,
      snippetStore: snippetStore,
      blobStore: blobStore,
      paster: paster,
      frontmostAppTracker: frontmostAppTracker
    )
    self.pickerViewModel = viewModel

    let panel = PickerPanel {
      PickerView(viewModel: viewModel)
    }
    self.pickerPanel = panel

    let snippetEditorWindow = SnippetEditorWindow()
    self.snippetEditorWindow = snippetEditorWindow

    // Task 12 (item preview): owns the one preview-surface controller —
    // see `ItemPreviewController`'s doc comment for why this presents via a
    // non-key child `NSPanel` rather than `NSPopover`/`.popover`.
    let itemPreviewController = ItemPreviewController()
    self.itemPreviewController = itemPreviewController

    // Set after `panel`/`clipboardMonitor`/`snippetEditorWindow` exist to
    // break the construction-order cycle: the panel's own SwiftUI content
    // needs a way to dismiss the panel that hosts it, but the panel doesn't
    // exist yet while that content is being built. See
    // `PickerViewModel.dismiss`'s doc comment.
    viewModel.dismiss = { [weak panel] in panel?.hide() }
    panel.onWillShow = { [weak viewModel] in viewModel?.willShow() }
    panel.onDidHide = { [weak viewModel, weak itemPreviewController] in
      viewModel?.didHide()
      // Belt-and-suspenders alongside `didHide()` clearing
      // `previewTargetID` (which `PickerView`'s own `.onChange` also routes
      // to `itemPreviewController.hide()` via `viewModel.updatePreview`):
      // explicitly hides the preview panel here too, so it can never be
      // left showing after the picker itself hides regardless of SwiftUI
      // update timing.
      itemPreviewController?.hide()
    }
    panel.onCommandDelete = { [weak viewModel] in viewModel?.deleteHighlighted() }

    // Task 12 (item preview): drives the non-key preview panel from
    // `previewTargetID` changes — see `PickerView`'s top doc comment for
    // the `.onChange` → `viewModel.updatePreview` → here → `panel.frame`
    // used as the coarse anchor. `panel.frame` (not per-row rects) is an
    // acceptable first-pass anchor per the task brief — the preview sits
    // beside the whole picker, Maccy-style.
    viewModel.updatePreview = { [weak panel, weak itemPreviewController, weak viewModel] item in
      itemPreviewController?.update(
        item: item,
        blobStore: blobStore,
        besideAnchor: panel?.frame,
        onPreviewHover: { hovering in viewModel?.previewHoverChanged(hovering) }
      )
    }

    // T23 fix round: shows/hides the snippet editor. `onSave` decides
    // create vs. update based on the `mode` this exact `show(...)` call was
    // given — `SnippetEditorWindow` itself has no opinion on `SnippetStore`.
    // `pickerPanel: panel` lets the editor lay itself out as a side-by-side
    // pair with the picker instead of screen-centered — this may reposition
    // `panel`'s frame (never its size) to make room, so the two windows
    // always end up with distinct left edges and, whenever they can fit the
    // screen, zero overlap — see
    // `SnippetEditorWindow.positionRelativeToPicker(_:)`/
    // `WindowPlacement.pairLayout`.
    // `onClose` fires once the editor closes for any reason (Save, Cancel,
    // red button, ⌘W — see that type's doc comment) and re-keys `panel` +
    // refocuses its search field, so the user lands back in a usable picker
    // rather than a picker that's visible but no longer receiving input.
    viewModel.presentSnippetEditor = {
      [weak snippetEditorWindow, weak viewModel, weak panel] mode in
      guard let snippetEditorWindow, let viewModel else { return }
      snippetEditorWindow.show(
        mode: mode,
        pickerPanel: panel,
        onSave: { title, body, keyword in
          switch mode {
          case .create, .createFromClip:
            viewModel.createSnippet(title: title, body: body, keyword: keyword)
          case .edit(let snippet):
            viewModel.updateSnippet(snippet.id, title: title, body: body, keyword: keyword)
          }
        },
        onClose: { [weak panel, weak viewModel] in
          guard let panel, panel.isVisible else { return }
          panel.makeKey()
          viewModel?.refocusSearchField()
        }
      )
    }

    // Fix round 1, bug #1: tell the running monitor to ignore the
    // changeCount produced by the picker's own copy-on-select write, so it
    // doesn't get recaptured as a new external copy on the next poll. See
    // `PickerViewModel.suppressOwnPasteboardWrite`'s and
    // `ClipboardMonitor.ignore(changeCount:)`'s doc comments.
    let monitor = clipboardMonitor
    viewModel.suppressOwnPasteboardWrite = { [weak monitor] changeCount in
      monitor?.ignore(changeCount: changeCount)
    }

    // T50/T51 (DB-virtualization): the picker no longer polls `ClipStore`
    // on a timer — instead, the one shared `ClipboardMonitor` this
    // environment already owns pushes a live update straight into the
    // picker on every real capture, via the new `onCapture` hook. This is
    // the one choke point both live (this) and self-write-suppressed
    // (above) pasteboard observations already share. See
    // `PickerViewModel.handleNewCapture()`'s doc comment for why this is a
    // single bounded page-0 requery, not a full-table refetch.
    monitor.onCapture = { [weak viewModel] _ in
      viewModel?.handleNewCapture()
    }

    // Snippet-expansion clipboard fallback (`ClipboardSelectionReplacer`):
    // pause capture while it borrows the clipboard for the synthesized
    // copy/paste, then ignore the restore's change and resume — so the
    // transient copy/paste (the selection and the pasted body) never lands in
    // history and the restored (original) clipboard isn't recaptured.
    clipboardReplacer.beginSuppression = { [weak monitor] in monitor?.pause() }
    clipboardReplacer.endSuppression = { [weak monitor] in
      monitor?.ignore(changeCount: NSPasteboard.general.changeCount)
      monitor?.resume()
    }
  }

  /// Starts continuous clipboard capture on a real timer
  /// (`ClipboardMonitor.defaultPollInterval`). Call exactly once, from
  /// `AppDelegate.applicationDidFinishLaunching`.
  func startCapture() {
    clipboardMonitor.start()
  }

  /// Registers the global ⌥⌘V hotkey (plan task T27, fix round 2) that
  /// opens the picker from anywhere, via the exact same `showPicker()` path
  /// the menu bar's "Open Clipnest" item already uses, and (T9) the global
  /// ⌥⌘E hotkey that triggers `snippetExpander`. Call exactly once, from
  /// `AppDelegate.applicationDidFinishLaunching`.
  func registerHotkey() {
    HotkeyManager.register { [weak self] in self?.showPicker() }
    HotkeyManager.registerExpandSnippet { [weak self] in
      guard let self else { return }
      Task { await self.snippetExpander.expand() }
    }
  }

  /// Shows the picker panel — the menu bar "Open Clipnest" item's action,
  /// and (fix round 2) the global hotkey's action. Both triggers share this
  /// one method; nothing about it is trigger-specific.
  ///
  /// T16: records the frontmost app *before* the panel is shown, so
  /// `PickerViewModel.select(_:)` later has the right paste target — see
  /// `FrontmostAppTracker`'s doc comment for why this must happen at
  /// trigger time rather than lazily at select time.
  func showPicker() {
    frontmostAppTracker.record()
    pickerPanel.show()
  }
}
