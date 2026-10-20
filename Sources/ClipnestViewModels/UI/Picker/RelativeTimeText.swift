// RelativeTimeText.swift
//
// T-AUD-VO: a pure "N minutes ago" formatter for assistive-technology labels
// (VoiceOver on macOS, Orca on Linux). Deliberately NOT Foundation's
// `RelativeDateTimeFormatter`/`Date.RelativeFormatStyle`: neither is
// guaranteed identical (or even present) across the macOS and Linux
// Foundations, and a label builder that is unit-tested on both must produce
// the same words on both. English-only, matching the rest of the picker's
// strings.
import Foundation

public enum RelativeTimeText {
  static let justNow = "just now"
  private static let secondsPerMinute = 60
  private static let secondsPerHour = 3_600
  private static let secondsPerDay = 86_400

  /// "just now" under a minute (and for future dates), then "1 minute ago",
  /// "5 minutes ago", "2 hours ago", "3 days ago".
  public static func string(from date: Date, now: Date = Date()) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    guard seconds >= secondsPerMinute else { return justNow }
    if seconds < secondsPerHour {
      return unit(seconds / secondsPerMinute, "minute")
    }
    if seconds < secondsPerDay {
      return unit(seconds / secondsPerHour, "hour")
    }
    return unit(seconds / secondsPerDay, "day")
  }

  private static func unit(_ count: Int, _ name: String) -> String {
    "\(count) \(name)\(count == 1 ? "" : "s") ago"
  }
}
