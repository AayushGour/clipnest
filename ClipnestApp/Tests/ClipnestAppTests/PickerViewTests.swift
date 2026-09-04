// PickerViewTests.swift
//
// T-BUG1 (bug fix): `PickerView.handle(_:)` itself can't be exercised from a
// test — it takes a real `KeyPress`, and `KeyPress` (SwiftUI, macOS 14+) has
// no public initializer, so one can't be constructed outside SwiftUI's own
// key-event dispatch. `PickerView.returnAction(for:)` is the pure decision
// logic pulled out of `handle(_:)`'s `.return` case specifically so it CAN
// be tested: it takes `EventModifiers`, a plain `OptionSet` that IS
// constructable directly (`[.command]`, `EventModifiers(rawValue:)`, etc.) —
// same shape as `ShortcutHintsTests.swift`'s coverage of the other pure,
// zero-live-SwiftUI-dependency logic in this module.
//
// The bug: the bare `case .return` used to match ANY modifier combination
// other than `.option` — so ⌘Return, ⌃Return, and ⇧Return all silently ran
// the exact same action as plain Return, with no indication to the user
// that a distinct chord did nothing different. This suite locks down the
// fix: plain Return still selects, ⌥Return still selects plain text (the
// shipped "paste without formatting" feature — must NOT regress), and every
// other modifier combination the picker doesn't implement now maps to
// `.ignore` rather than being silently aliased to plain Return.

import Testing

// The `ClipnestApp` target's actual Swift module name is `Clipnest` (see
// `PRODUCT_NAME` in `project.yml`) — see `ItemKind+SFSymbolTests.swift`'s
// top doc comment for the full explanation. `EventModifiers` lives in
// SwiftUI/SwiftUICore, re-exported through `Clipnest`'s own `import
// SwiftUI`, so no separate `import SwiftUI` is needed here.
@testable import Clipnest

@Suite("PickerView.returnAction")
struct PickerViewReturnActionTests {

  @Test("Plain Return (no modifiers) selects the highlighted row")
  func plainReturnSelects() {
    #expect(PickerView.returnAction(for: []) == .select)
  }

  @Test(
    "Return with only incidental flags set (caps lock, numeric keypad) still counts as plain Return"
  )
  func incidentalModifiersDoNotDisqualifyPlainReturn() {
    #expect(PickerView.returnAction(for: [.capsLock]) == .select)
    #expect(PickerView.returnAction(for: [.numericPad]) == .select)
    #expect(PickerView.returnAction(for: [.capsLock, .numericPad]) == .select)
  }

  @Test("⌥Return selects the highlighted row as plain text — the shipped feature, unchanged")
  func optionReturnSelectsPlainText() {
    #expect(PickerView.returnAction(for: [.option]) == .selectPlainText)
  }

  @Test("⌥Return still selects plain text even alongside an incidental flag")
  func optionReturnWithIncidentalFlagStillSelectsPlainText() {
    #expect(PickerView.returnAction(for: [.option, .capsLock]) == .selectPlainText)
  }

  @Test("⌘Return is NOT silently aliased to plain Return — it's ignored (T-BUG1)")
  func commandReturnIsIgnored() {
    #expect(PickerView.returnAction(for: [.command]) == .ignore)
  }

  @Test("⌃Return is NOT silently aliased to plain Return — it's ignored (T-BUG1)")
  func controlReturnIsIgnored() {
    #expect(PickerView.returnAction(for: [.control]) == .ignore)
  }

  @Test("⇧Return is NOT silently aliased to plain Return — it's ignored (T-BUG1)")
  func shiftReturnIsIgnored() {
    #expect(PickerView.returnAction(for: [.shift]) == .ignore)
  }

  @Test("⌘⇧Return (multiple non-option modifiers) is also ignored, not treated as plain Return")
  func commandShiftReturnIsIgnored() {
    #expect(PickerView.returnAction(for: [.command, .shift]) == .ignore)
  }
}
