// WelcomeWindowSupport.swift
//
// T-WELCOME1-LX: the pure, unit-testable decisions behind `WelcomeWindow`
// (key handling, step badges, collapsed-row summaries), split out of the GTK
// widget code the same way `PickerKeyAction`/`KeyEventMapping` are.
import ClipnestViewModels

/// Keys the welcome window handles itself. Return is NOT here: it is the
/// window's default widget (Continue/Done), so a focused secondary button
/// keeps activating itself, per design.md "Keyboard / focus".
enum WelcomeKeyAction: Equatable {
  case close

  private enum Keyval {
    static let escape: UInt32 = 0xff1b
    static let wLower: UInt32 = 0x077
    static let wUpper: UInt32 = 0x057
  }

  /// `GdkModifierType` bits that make a chord "not plain Ctrl": Shift (1<<0),
  /// Alt/Mod1 (1<<3), Super (1<<26). Caps/Num Lock are deliberately ignored.
  private static let disqualifyingModifiers: UInt32 = (1 << 0) | (1 << 3) | (1 << 26)

  static func action(keyval: UInt32, state: UInt32) -> WelcomeKeyAction? {
    let hasControl = state & KeyEventMapping.controlMask != 0
    let hasOthers = state & disqualifyingModifiers != 0
    switch keyval {
    case Keyval.escape where !hasControl && !hasOthers:
      return .close
    case Keyval.wLower, Keyval.wUpper:
      return hasControl && !hasOthers ? .close : nil
    default:
      return nil
    }
  }
}

enum WelcomeStepBadge {
  static let skippedGlyph = "–"
  static let doneGlyph = "✓"

  /// Shape + text, never color alone (design.md Accessibility).
  static func text(for state: WelcomeStepState, number: Int) -> String {
    switch state {
    case .done: return doneGlyph
    case .skipped: return skippedGlyph
    case .current, .upcoming: return String(number)
    }
  }

  /// Spoken name for the check/dash badges; the numbers need none (the row
  /// group is labelled "Step N of 2: ...").
  static func accessibleLabel(for state: WelcomeStepState) -> String? {
    switch state {
    case .done: return WelcomeCopy.doneBadgeLabel
    case .skipped: return WelcomeCopy.skippedBadgeLabel
    case .current, .upcoming: return nil
    }
  }
}

enum WelcomeRowSummary {
  /// The status line of a step that is not the current one (the current row
  /// shows its full body instead). `nil` = nothing to show.
  static func text(
    step: WelcomeStep, state: WelcomeStepState, hotkeyText: String?, permissionSummary: String,
    tryItStatus: String, openAtLoginStatus: String? = nil
  ) -> String? {
    switch (state, step) {
    case (.current, _):
      return nil
    case (.upcoming, .permission):
      return nil
    case (_, .openAtLogin):
      // Collapsed "Open Clipnest at login" row: On / Off.
      return openAtLoginStatus
    case (.upcoming, .tryIt), (.skipped, .tryIt):
      // Collapsed "Try your hotkey" row: the hotkey itself (or that none is set).
      return hotkeyText ?? WelcomeCopy.noHotkeyShort
    case (.skipped, .permission):
      return permissionSummary
    case (.done, .permission):
      return permissionSummary
    case (.done, .tryIt):
      return tryItStatus
    }
  }
}
