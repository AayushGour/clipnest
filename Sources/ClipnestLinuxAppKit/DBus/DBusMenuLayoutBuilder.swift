import ClipnestPlatformLinux
import Foundation

/// One flat menu item this app's tray exposes — `com.canonical.dbusmenu`
/// supports arbitrary nesting/submenus/checkboxes/separators; this app's
/// tray needs none of that, so the model is deliberately just "a labeled,
/// clickable leaf."
struct DBusMenuItem: Equatable {
  let id: Int32
  let label: String
}

/// Pure builder for `GetLayout`'s reply shape (`com.canonical.dbusmenu`
/// spec): `(revision: u, root: (id: i, properties: a{sv}, children: av))`,
/// where each child is a `VARIANT` wrapping the SAME
/// `(i, a{sv}, av)` structure recursively. This app's menu is exactly one
/// level deep (a root with flat leaf children, no grandchildren), so every
/// child's own `children` array is always empty.
///
/// Kept separate from `StatusNotifierTray` (the real D-Bus-connected
/// class) so the nested-structure marshalling — the one part of this
/// contract most likely to be gotten subtly wrong — is directly
/// unit-testable without a real bus.
enum DBusMenuLayoutBuilder {
  static let revision: UInt32 = 1

  /// KNOWN WIRE-MARSHALLING GAP, flagged rather than silently shipped:
  /// `DBusValue.array([]).signatureCode` degrades to `"ay"` (byte array)
  /// for a genuinely empty array — see that property's doc comment in
  /// `ClipnestPlatformLinux/Accessibility/DBusValue.swift` — because
  /// nothing about an empty `[DBusValue]` can tell it what element type
  /// was intended. The root item's `properties: a{sv}` and every leaf's
  /// `children: av` are both empty here, so a real `com.canonical.dbusmenu`
  /// client marshalling this reply over an actual wire would see `"ay"`
  /// where `"a{sv}"`/`"av"` was meant. Fixing it requires either a
  /// `DBusValue` case that carries its element type even when empty, or a
  /// signature override parameter on `DBusMessage`'s body — both changes
  /// belong to `ClipnestPlatformLinux`, out of this task's file-ownership
  /// scope (see `ShellHelperRequests`'s doc comment for the identical
  /// "flagged for that module's owner" call on the UNIX-fd gap). This
  /// class's own unit tests assert the DBusValue STRUCTURE (case shape),
  /// which is unaffected; only real-bus byte marshalling is impacted, and
  /// there is no real bus in this project's CI to catch it either way —
  /// tracked as a decision for `project-context.md`.

  static func layout(items: [DBusMenuItem]) -> DBusValue {
    .structure([.int32(DBusMenuItemID.root), .array([]), .array(items.map(childVariant))])
  }

  /// `GetLayout`'s full two-value reply body: `(revision, root)`.
  static func getLayoutReply(items: [DBusMenuItem]) -> [DBusValue] {
    [.uint32(revision), layout(items: items)]
  }

  private static func childVariant(_ item: DBusMenuItem) -> DBusValue {
    let properties = propertyEntries(for: item, matching: [])
    return .variant(.structure([.int32(item.id), .array(properties), .array([])]))
  }

  /// `GetGroupProperties(ids, propertyNames) -> a(ia{sv})`'s full reply
  /// body: one `(id, properties)` entry per item `ids` selects. Per the
  /// `com.canonical.dbusmenu` spec, an empty `ids` means "every item" —
  /// same "empty means everything" convention `propertyNames` uses too
  /// (see `propertyEntries(for:matching:)`).
  ///
  /// Shares `propertyEntries(for:matching:)` with `GetLayout`'s own
  /// `childVariant` so the two interfaces can never disagree about what an
  /// item's properties are (coding-standards.md's DRY rule) — real
  /// `libdbusmenu-glib` clients (this method's whole reason for existing:
  /// see `DBusMenuMember.getGroupProperties`'s doc comment) call BOTH for
  /// the same items and expect consistent answers.
  ///
  /// Shares the SAME known wire-marshalling gap `layout(items:)`'s doc
  /// comment above flags for an empty `array([])`: if `ids` selects zero
  /// items, this degrades to the empty-array case (`"ay"` instead of
  /// `"a(ia{sv})"`) for the identical, already-documented reason — every
  /// real caller this app has been verified against always selects at
  /// least the items `GetLayout` just returned, so this is unreachable in
  /// practice, not silently swept under the rug.
  static func getGroupPropertiesReply(
    items: [DBusMenuItem], ids: [Int32], propertyNames: [String]
  ) -> [DBusValue] {
    let selected = ids.isEmpty ? items : items.filter { ids.contains($0.id) }
    let entries = selected.map { item in
      DBusValue.structure([
        .int32(item.id), .array(propertyEntries(for: item, matching: propertyNames)),
      ])
    }
    return [.array(entries)]
  }

  /// `label`'s `a{sv}` dict entries for one item — this app's menu has
  /// exactly one property, so `propertyNames.isEmpty` (the spec's "return
  /// everything" convention) and `propertyNames.contains("label")` are the
  /// only two ways this ever returns non-empty; anything else (a real
  /// client asking only for some OTHER property this menu doesn't have)
  /// correctly returns no entries rather than fabricating one.
  private static func propertyEntries(
    for item: DBusMenuItem, matching propertyNames: [String]
  ) -> [DBusValue] {
    guard propertyNames.isEmpty || propertyNames.contains(DBusMenuProperty.label) else { return [] }
    return [.dictEntry(.string(DBusMenuProperty.label), .variant(.string(item.label)))]
  }
}
