import ClipnestPlatformLinux
import Foundation

/// Decoded form of `ShowPicker(a{sv})`'s options dict. Carrying
/// pointer/monitor/focus in the SAME message the extension's
/// `ShortcutActivated` signal (or a future caller) sends removes a round
/// trip and a race: the compositor is the only place that knows both the
/// pointer position and the focused window at the instant of the keypress
/// — by the time this app's process could ask for them separately, either
/// could have changed.
public struct ShowPickerOptions: Equatable, Sendable {
  public var pointer: (x: Int32, y: Int32)?
  public var monitor: Int32?
  /// Raw `focus` sub-dictionary (whatever `GetFocusedApp()`-shaped info
  /// the caller included), kept as opaque key/value pairs rather than
  /// parsed further here — nothing in this app's `ShowPicker` handler
  /// needs more than "was focus info provided at all" today, and decoding
  /// its fields is `ShellHelperClient`'s job (`GetFocusedApp`'s own
  /// return shape), not this generic options parser's.
  public var focusKeys: [String]

  public static let empty = ShowPickerOptions(pointer: nil, monitor: nil, focusKeys: [])

  public init(pointer: (x: Int32, y: Int32)?, monitor: Int32?, focusKeys: [String]) {
    self.pointer = pointer
    self.monitor = monitor
    self.focusKeys = focusKeys
  }

  public static func == (lhs: ShowPickerOptions, rhs: ShowPickerOptions) -> Bool {
    lhs.pointer?.x == rhs.pointer?.x && lhs.pointer?.y == rhs.pointer?.y
      && lhs.monitor == rhs.monitor && lhs.focusKeys == rhs.focusKeys
  }

  /// Parses an `a{sv}` `DBusValue` (the shape `ShowPicker`'s single
  /// argument arrives as) into `ShowPickerOptions`. Never fails outright —
  /// an absent/malformed key is simply left `nil`/empty, matching
  /// `PickerWindow.show(at:)`'s own "`nil` => compositor centres it"
  /// graceful-default contract.
  public static func parse(_ value: DBusValue) -> ShowPickerOptions {
    guard case .array(let entries) = value else { return .empty }

    var pointerX: Int32?
    var pointerY: Int32?
    var monitor: Int32?
    var focusKeys: [String] = []

    for entry in entries {
      guard case .dictEntry(.string(let key), .variant(let inner)) = entry else { continue }
      switch key {
      case ShowPickerOptionKey.pointerX:
        if case .int32(let x) = inner { pointerX = x }
      case ShowPickerOptionKey.pointerY:
        if case .int32(let y) = inner { pointerY = y }
      case ShowPickerOptionKey.monitor:
        if case .int32(let m) = inner { monitor = m }
      case ShowPickerOptionKey.focus:
        if case .array(let focusEntries) = inner {
          focusKeys = focusEntries.compactMap { entry -> String? in
            guard case .dictEntry(.string(let focusKey), _) = entry else { return nil }
            return focusKey
          }
        }
      default: break
      }
    }

    let pointer: (x: Int32, y: Int32)?
    if let pointerX, let pointerY {
      pointer = (pointerX, pointerY)
    } else {
      pointer = nil
    }
    return ShowPickerOptions(pointer: pointer, monitor: monitor, focusKeys: focusKeys)
  }

  /// The inverse of `parse(_:)` — builds the `a{sv}` body `ShowPicker`
  /// expects. Used by `ShellHelperClient` to translate a `ShortcutActivated`
  /// signal's already-typed fields back into the exact wire shape this
  /// app's own `ShowPicker` handler parses, so the two stay provably in
  /// sync (round-tripped by `ShowPickerOptionsTests`).
  public func encoded() -> DBusValue {
    var entries: [DBusValue] = []
    if let pointer {
      entries.append(
        .dictEntry(.string(ShowPickerOptionKey.pointerX), .variant(.int32(pointer.x))))
      entries.append(
        .dictEntry(.string(ShowPickerOptionKey.pointerY), .variant(.int32(pointer.y))))
    }
    if let monitor {
      entries.append(.dictEntry(.string(ShowPickerOptionKey.monitor), .variant(.int32(monitor))))
    }
    if !focusKeys.isEmpty {
      let focusEntries = focusKeys.map {
        DBusValue.dictEntry(.string($0), .variant(.string("")))
      }
      entries.append(.dictEntry(.string(ShowPickerOptionKey.focus), .variant(.array(focusEntries))))
    }
    return .array(entries)
  }
}
