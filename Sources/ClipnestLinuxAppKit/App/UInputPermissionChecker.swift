import ClipnestGTK
import Foundation

#if canImport(Glibc)
  import Glibc
#endif

/// T-OPT3: reads the CURRENT, real state of the uinput auto-paste grant —
/// see `UInputPermissionStatus`'s doc comment (`ClipnestGTK`) for why this
/// is two independent booleans rather than one combined flag. Every check
/// here is read-only and side-effect-free (`access(2)`/`getgrnam(3)`/
/// `getpwuid(3)` — never `open()`, never an `ioctl`, nothing that could
/// itself create or destroy a virtual input device the way
/// `UInputDevice.open()` (`ClipnestPlatformLinux`) does), so it's cheap
/// enough to call every time Settings is shown, not just once at launch.
///
/// Manual/integration-verify only for the two real syscall wrappers below
/// (`isDeviceAccessible`/`groupMembers(named:)`) — this project's own bare
/// build/test container has no `/dev/uinput` and no `clipnest-input` group,
/// mirroring `LinuxEventSynthesizerFactory`'s identical "the real I/O can
/// only be exercised against a real device/group, neither of which exist in
/// CI" note. The one genuinely pure decision (`isMember(username:of:)`) is
/// unit-tested directly instead, same split that file's own
/// `LinuxEventSynthesizerSelection.choose` documents.
public enum UInputPermissionChecker {
  /// Mirrors `UInputDevice.open(devicePath:)`'s own default
  /// (`ClipnestPlatformLinux`) — duplicated as one small, greppable literal
  /// rather than reaching into that module for a shared constant it doesn't
  /// currently export, the same "one cheap, documented duplicate" precedent
  /// `LinuxAppEnvironment.installedVersion`'s doc comment already uses.
  public static let defaultDevicePath = "/dev/uinput"

  /// The system group created (empty) by `debian/clipnest.postinst` and
  /// granted via `packaging/linux/scripts/clipnest-grant-input` — see that
  /// script's own doc comment. Named here as the one Swift-side reference to
  /// it (coding-standards.md: no magic strings), even though the
  /// shell/udev/polkit side of this name lives entirely under
  /// `packaging/**`, out of this task's owned-files scope to touch.
  public static let grantedGroupName = "clipnest-input"

  public static func currentStatus(
    devicePath: String = defaultDevicePath, groupName: String = grantedGroupName
  ) -> UInputPermissionStatus {
    UInputPermissionStatus(
      isUInputAccessible: isDeviceAccessible(devicePath),
      isInClipnestInputGroup: isCurrentUser(inGroup: groupName))
  }

  /// Side-effect-free: `access(2)` checks the REAL (not effective) uid/gid
  /// and this process's current supplementary groups directly against the
  /// file's permission bits — it does not open the device, so unlike
  /// `UInputDevice.open()` this never creates/destroys a virtual input
  /// device and never blocks for `InputConstants.uinputDeviceSettleDelay`.
  /// `UInputDevice.open()` opens `/dev/uinput` `O_WRONLY`, so `W_OK` is the
  /// bit that matters here; `F_OK` is implied (a nonexistent path also
  /// fails `W_OK`), which correctly reports "not accessible" whether the
  /// cause is a missing device node (uinput kernel module not loaded) or a
  /// real permission denial — both mean the same thing to this tab: auto-
  /// paste's uinput tier is not usable right now.
  static func isDeviceAccessible(_ path: String) -> Bool {
    #if canImport(Glibc)
      return Glibc.access(path, W_OK) == 0
    #else
      return false
    #endif
  }

  /// Reads `/etc/group` (via NSS's `getgrnam(3)`) directly, NOT this
  /// process's live supplementary-group list (`getgroups(2)`) — those two
  /// can legitimately disagree, which is exactly the gap
  /// `UInputPermissionStatus`'s doc comment describes: `usermod -aG`
  /// updates the on-disk group database immediately, but a process's own
  /// supplementary groups are fixed at login and don't pick up a new grant
  /// until the user logs out and back in.
  static func isCurrentUser(inGroup groupName: String) -> Bool {
    guard let username = currentUsername(), let members = groupMembers(named: groupName) else {
      return false
    }
    return isMember(username: username, of: members)
  }

  /// Pure decision, unit-tested directly — no group-database I/O.
  static func isMember(username: String, of members: [String]) -> Bool {
    members.contains(username)
  }

  /// Real `getgrnam(3)` lookup — `nil` if the group doesn't exist at all
  /// (e.g. the `clipnest` package was never installed/configured on this
  /// machine).
  static func groupMembers(named groupName: String) -> [String]? {
    #if canImport(Glibc)
      guard let group = getgrnam(groupName) else { return nil }
      guard let members = group.pointee.gr_mem else { return [] }
      var result: [String] = []
      var index = 0
      while let memberPointer = members[index] {
        result.append(String(cString: memberPointer))
        index += 1
      }
      return result
    #else
      return nil
    #endif
  }

  /// Real `getpwuid(3)` lookup for this process's own real uid — `nil` only
  /// if the uid has no passwd entry at all (never expected in practice for
  /// a real logged-in user).
  static func currentUsername() -> String? {
    #if canImport(Glibc)
      guard let passwd = getpwuid(getuid()) else { return nil }
      return String(cString: passwd.pointee.pw_name)
    #else
      return nil
    #endif
  }
}
