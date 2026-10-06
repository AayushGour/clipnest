// PickerViewModelFactory.swift
//
// Builds a `PickerViewModel` wired entirely to test doubles/in-memory Core
// fakes — never the real `NSPasteboard.general`/`NSWorkspace`/`CGEvent`
// default parameters `PickerViewModel.init` otherwise falls back to. Shared
// by every `PickerViewModelTests` case so the "how do I construct one of
// these safely" wiring lives in exactly one place (DRY per
// coding-standards.md).

import ClipnestCore
import Foundation

// The `ClipnestApp` target's actual Swift module name is `Clipnest` (see
// `PRODUCT_NAME` in `project.yml`) — see `ItemKind+SFSymbolTests.swift`'s
// top doc comment for the full explanation.
@testable import ClipnestViewModels

@MainActor
func makeTestPickerViewModel(
  clipStore: any ClipStore = InMemoryClipStore(blobStore: makeTempBlobStore().blobStore),
  snippetStore: any SnippetStore = InMemorySnippetStore(),
  pasteboard: any PasteboardWriting = FakePasteboardWriting(),
  blobStore: BlobStore = makeTempBlobStore().blobStore,
  // T-RT2: `nil` by default (every existing call site's exact prior
  // behavior — no subscription, no behavior change) — pass a real
  // `NotifyingClipStore.changes` (built from the SAME `clipStore` passed
  // above) to exercise the "an external mutation refreshes an open picker"
  // path. See `PickerViewModelStoreChangeTests.swift`.
  storeChanges: ClipStoreChangeBroadcaster? = nil
) -> PickerViewModel {
  PickerViewModel(
    clipStore: clipStore,
    snippetStore: snippetStore,
    pasteboard: pasteboard,
    blobStore: blobStore,
    paster: Paster(
      pasteboard: FakePasteboardWriting(),
      eventSynthesizer: FakeEventSynthesizing(),
      isAccessibilityGranted: { false }
    ),
    frontmostAppTracker: FrontmostAppTracker(provider: FakeFrontmostAppReferenceProviding()),
    storeChanges: storeChanges
  )
}
