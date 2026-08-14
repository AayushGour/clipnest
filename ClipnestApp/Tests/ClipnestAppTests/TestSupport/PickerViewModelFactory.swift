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
@testable import Clipnest

@MainActor
func makeTestPickerViewModel(
  clipStore: any ClipStore = InMemoryClipStore(blobStore: makeTempBlobStore().blobStore),
  snippetStore: any SnippetStore = InMemorySnippetStore(),
  blobStore: BlobStore = makeTempBlobStore().blobStore
) -> PickerViewModel {
  PickerViewModel(
    clipStore: clipStore,
    snippetStore: snippetStore,
    pasteboard: FakePasteboardWriting(),
    blobStore: blobStore,
    paster: Paster(
      pasteboard: FakePasteboardWriting(),
      eventSynthesizer: FakeEventSynthesizing(),
      isAccessibilityGranted: { false }
    ),
    frontmostAppTracker: FrontmostAppTracker(provider: FakeFrontmostAppReferenceProviding())
  )
}
