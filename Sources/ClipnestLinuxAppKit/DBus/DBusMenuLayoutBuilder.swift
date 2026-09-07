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

  /// **FIXED (was a KNOWN WIRE-MARSHALLING GAP, confirmed connection-fatal
  /// against a real bus — see `debian/README.source`'s "Known gap #4").**
  /// `DBusValue.array([]).signatureCode` used to degrade to `"ay"` (byte
  /// array) for a genuinely empty array, because nothing about an empty
  /// `[DBusValue]` can tell it what element type was intended. The root
  /// item's `properties: a{sv}` and every leaf's `children: av` are both
  /// ALWAYS empty here (this app's menu is deliberately one level deep),
  /// so a real `com.canonical.dbusmenu` client marshalling `GetLayout`'s
  /// reply over the actual wire saw `"ay"` where `"a{sv}"`/`"av"` was
  /// meant — and disconnected mid-reply
  /// (`LIBDBUSMENU-GLIB-WARNING: Getting layout failed: Operation was
  /// cancelled`, reproduced with `dbus-send` and real `gnome-panel`).
  /// Fixed by `DBusValue.emptyArray(elementSignature:)`/`.array(
  /// _:elementSignature:)` (`ClipnestPlatformLinux/Accessibility/
  /// DBusValue.swift`) — every empty array below now carries its true
  /// element signature explicitly instead of relying on inference from a
  /// (nonexistent) first element.

  static func layout(items: [DBusMenuItem]) -> DBusValue {
    .structure([
      .int32(DBusMenuItemID.root),
      .emptyArray(elementSignature: DBusElementSignature.stringVariantDictEntry),
      .array(items.map(childVariant), elementSignature: DBusElementSignature.variant),
    ])
  }

  /// `GetLayout`'s full two-value reply body: `(revision, root)`.
  static func getLayoutReply(items: [DBusMenuItem]) -> [DBusValue] {
    [.uint32(revision), layout(items: items)]
  }

  private static func childVariant(_ item: DBusMenuItem) -> DBusValue {
    // `properties` is provably non-empty: `matching: []` means "return
    // everything" (`propertyEntries`'s own doc comment), and every item
    // has a `label`. `children` is ALWAYS empty — this app's menu never
    // nests past one level — so it needs the explicit `av` signature.
    let properties = propertyEntries(for: item, matching: [])
    return .variant(
      .structure([
        .int32(item.id), .array(properties),
        .emptyArray(elementSignature: DBusElementSignature.variant),
      ]))
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
  /// Both this reply's outer `a(ia{sv})` array AND each item's own
  /// `a{sv}` properties array CAN be genuinely empty here — `ids` naming
  /// only stale/unknown IDs makes `selected` empty, and `propertyNames`
  /// naming only some other property this menu doesn't have makes a
  /// given item's own properties empty (see `propertyEntries(for:
  /// matching:)`) — so both go through `.array(_:elementSignature:)`
  /// rather than the plain, inference-based `.array(_:)` that used to
  /// silently mis-type an empty result the same way `layout(items:)`'s
  /// doc comment above describes.
  static func getGroupPropertiesReply(
    items: [DBusMenuItem], ids: [Int32], propertyNames: [String]
  ) -> [DBusValue] {
    let selected = ids.isEmpty ? items : items.filter { ids.contains($0.id) }
    let entries = selected.map { item in
      DBusValue.structure([
        .int32(item.id),
        .array(
          propertyEntries(for: item, matching: propertyNames),
          elementSignature: DBusElementSignature.stringVariantDictEntry),
      ])
    }
    return [.array(entries, elementSignature: DBusElementSignature.menuGroupPropertiesEntry)]
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
