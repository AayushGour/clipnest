import Testing

@testable import ClipnestGTK

/// T-OPT3: unit-tests the pure Permissions-tab decision logic
/// (`PermissionsTabPresentation`), separated from GTK widget code —
/// mirrors `GTKSnippetFormValidationTests`'s identical "pure logic behind a
/// GTK tab, tested directly" split.
@Suite("PermissionsTabPresentation")
struct GTKPermissionsTabPresentationTests {
  @Test("Neither granted nor in the group: available to request, no re-login note")
  func neitherGrantedShowsAvailable() {
    let status = UInputPermissionStatus(isUInputAccessible: false, isInClipnestInputGroup: false)
    #expect(PermissionsTabPresentation.availability(for: status) == .available)
    #expect(PermissionsTabPresentation.grantButtonVisible(for: status))
    #expect(!PermissionsTabPresentation.showsReloginNote(for: status))
  }

  @Test(
    "In the group but /dev/uinput not yet accessible: pending re-login — the exact gap this whole feature exists to explain"
  )
  func inGroupButNotYetAccessibleShowsPendingRelogin() {
    let status = UInputPermissionStatus(isUInputAccessible: false, isInClipnestInputGroup: true)
    #expect(PermissionsTabPresentation.availability(for: status) == .pendingRelogin)
    #expect(!PermissionsTabPresentation.grantButtonVisible(for: status))
    #expect(PermissionsTabPresentation.showsReloginNote(for: status))
  }

  @Test("Fully granted: no button, no re-login note")
  func fullyGrantedShowsGranted() {
    let status = UInputPermissionStatus(isUInputAccessible: true, isInClipnestInputGroup: true)
    #expect(PermissionsTabPresentation.availability(for: status) == .granted)
    #expect(!PermissionsTabPresentation.grantButtonVisible(for: status))
    #expect(!PermissionsTabPresentation.showsReloginNote(for: status))
  }

  @Test(
    "uinput accessible but somehow not in the group still counts as granted — accessibility is the ground truth, not the group-database read"
  )
  func accessibleWithoutGroupStillCountsGranted() {
    let status = UInputPermissionStatus(isUInputAccessible: true, isInClipnestInputGroup: false)
    #expect(PermissionsTabPresentation.availability(for: status) == .granted)
    #expect(!PermissionsTabPresentation.grantButtonVisible(for: status))
  }

  @Test("Status lines report Yes/No truthfully for each independent flag")
  func statusLinesReflectEachFlag() {
    let notAccessible = UInputPermissionStatus(
      isUInputAccessible: false, isInClipnestInputGroup: false)
    #expect(
      PermissionsTabPresentation.uinputAccessibleLine(for: notAccessible)
        == "/dev/uinput accessible right now: No")
    #expect(
      PermissionsTabPresentation.groupMembershipLine(for: notAccessible)
        == "In the clipnest-input group: No")

    let accessible = UInputPermissionStatus(isUInputAccessible: true, isInClipnestInputGroup: true)
    #expect(
      PermissionsTabPresentation.uinputAccessibleLine(for: accessible)
        == "/dev/uinput accessible right now: Yes")
    #expect(
      PermissionsTabPresentation.groupMembershipLine(for: accessible)
        == "In the clipnest-input group: Yes")
  }

  @Test("The security-narrowing explanation names clipnest-input, not input, without overclaiming")
  func securityExplanationNamesTheNarrowerGroup() {
    let text = PermissionsTabPresentation.securityExplanationText
    #expect(text.contains("clipnest-input"))
    #expect(text.contains("broader \"input\" group"))
    #expect(text.contains("/dev/uinput"))
  }

  @Test("The no-grant explanation frames clipboard-only as normal, not an error")
  func explanationDoesNotReadAsAnError() {
    let text = PermissionsTabPresentation.explanationText
    #expect(text.contains("clipboard"))
    // The copy explicitly reassures the reader with the phrase "not an
    // error" — so this checks for THAT exact phrase, not bare absence of
    // the substring "error" (which the reassurance itself would trivially
    // contain and falsely fail this check).
    #expect(text.contains("not an error"))
    #expect(!text.lowercased().contains("broken"))
  }
}
