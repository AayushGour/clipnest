// FakeEventSynthesizing.swift
//
// A no-op `EventSynthesizing` fake so any `Paster` constructed for a test
// never posts a real `CGEvent` — per coding-standards.md ("NO synthesized
// key events... from a test"). `PickerViewModelTests` only needs this to
// satisfy `Paster`'s initializer; none of its tests exercise the paste
// path (`select`/`pasteSnippet`), so this is never actually invoked, but
// injecting it (rather than falling back to the real `CGEventSynthesizer`)
// keeps the test double fully real-system-free regardless.

import ClipnestCore
import Foundation

final class FakeEventSynthesizing: EventSynthesizing, @unchecked Sendable {
  private(set) var invocationCount = 0

  func synthesizeCommandV(targeting app: FrontmostAppRef) throws {
    invocationCount += 1
  }
}
