// AccessibilityPermissionCopy.swift
//
// Wording shared by the macOS Settings Permissions tab and the welcome
// window's step 1, so the stale-TCC-entry guidance is never forked.

public enum AccessibilityPermissionCopy {
  /// Why a listed-and-switched-on entry can still not work.
  public static let staleEntryExplanation =
    """
    Clipnest is signed locally, so macOS ties the permission to this \
    exact build. After Clipnest is updated or rebuilt, the old entry \
    stays in the list but no longer matches.
    """

  /// The fix.
  public static let staleEntryRemedy =
    """
    Select Clipnest in System Settings › Privacy & Security › \
    Accessibility, remove it with the − button, then add it again. \
    Turning the switch off and on again does not fix it.
    """
}
