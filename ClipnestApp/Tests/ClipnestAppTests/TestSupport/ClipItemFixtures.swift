// ClipItemFixtures.swift
//
// A small `ClipItem` builder shared by every `PickerViewModelTests` case
// that needs one — keeps each test's `ClipItem(...)` call down to just the
// fields that test actually cares about, per coding-standards.md's DRY rule
// (this is the second call site that needed a differently-defaulted
// `ClipItem`, the first real duplicate).

import ClipnestCore
import Foundation

func makeClipItem(
  kind: ItemKind = .text,
  previewText: String = "preview",
  contentHash: String = UUID().uuidString,
  pinned: Bool = false,
  pinnedAt: Date? = nil,
  blobPath: String? = nil,
  fileReference: String? = nil
) -> ClipItem {
  ClipItem(
    kind: kind,
    previewText: previewText,
    contentHash: contentHash,
    pinned: pinned,
    pinnedAt: pinnedAt,
    blobPath: blobPath,
    fileReference: fileReference
  )
}
