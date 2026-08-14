// FakeFrontmostAppReferenceProviding.swift
//
// A `FrontmostAppReferenceProviding` fake that never calls the real
// `NSWorkspace` — used to build a `FrontmostAppTracker` for tests without
// touching real system state, matching this file's sibling fakes. None of
// `PickerViewModelTests`' tests call `willShow()`'s eventual paste path (the
// only place `FrontmostAppTracker.consume()` is read), so this is
// effectively unused at runtime — it exists so `PickerViewModel`'s
// initializer never falls back to the real `WorkspaceFrontmostAppReferenceProvider`.

import ClipnestCore
import Foundation

final class FakeFrontmostAppReferenceProviding: FrontmostAppReferenceProviding, @unchecked Sendable
{
  var appToReturn: FrontmostAppRef?

  func currentFrontmostAppRef() -> FrontmostAppRef? {
    appToReturn
  }
}
