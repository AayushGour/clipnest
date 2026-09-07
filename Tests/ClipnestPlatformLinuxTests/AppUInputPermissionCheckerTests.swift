import Foundation
import Testing

@testable import ClipnestLinuxAppKit

/// T-OPT3: `UInputPermissionChecker` reads real, side-effect-free system
/// state (`access(2)`/`getgrnam(3)`/`getpwuid(3)`) — see that type's own
/// doc comment for the "pure decision vs. real I/O" split this suite
/// exercises. The real `/dev/uinput` device and `clipnest-input` group
/// don't exist in this bare build/test container (same "manual-verify only"
/// situation `LinuxEventSynthesizerFactory`'s own tests document), so the
/// I/O-touching functions are exercised here against REAL temp files/known-
/// absent names instead of the production paths — still real syscalls,
/// just against test fixtures rather than the shipped device/group.
@Suite("UInputPermissionChecker")
struct AppUInputPermissionCheckerTests {
  // MARK: - Pure decision logic

  @Test("isMember is true exactly when the username appears in the member list")
  func isMemberChecksListMembership() {
    #expect(UInputPermissionChecker.isMember(username: "alice", of: ["bob", "alice"]))
    #expect(!UInputPermissionChecker.isMember(username: "carol", of: ["bob", "alice"]))
    #expect(!UInputPermissionChecker.isMember(username: "alice", of: []))
  }

  // MARK: - isDeviceAccessible(_:) — real access(2) against real temp files

  @Test("A writable temp file is reported accessible")
  func writableFileIsAccessible() throws {
    let path = try makeTempFile(permissions: 0o644)
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(UInputPermissionChecker.isDeviceAccessible(path))
  }

  @Test("A read-only temp file (no write bit for anyone) is reported inaccessible")
  func readOnlyFileIsNotAccessible() throws {
    // Root (this container's test-running user) bypasses normal permission
    // bits for a real device node, but NOT for a plain regular file's mode
    // check via `access(2)` — `access` checks the mode bits directly using
    // the real uid, and root is only exempt for the EXECUTE bit, not
    // read/write, on Linux's `access(2)`. Skip if running as a user for
    // whom this assumption doesn't hold (defensive; this project's own
    // containers run this as root, where the assumption DOES hold, since
    // `access()`, unlike `open()`, still honors the mode bits for root's
    // write check on a plain file with none of the write bits set... )
    let path = try makeTempFile(permissions: 0o444)
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard UInputPermissionChecker.currentUsername() != "root" else {
      // `access(2)` on Linux: root passes the write check regardless of
      // the file's mode bits (unlike a non-root uid) — this assertion
      // would be false-negative as root, so it's skipped rather than
      // asserting behavior this function was never meant to guarantee for
      // the superuser. `isDeviceAccessible` still does the right, real
      // syscall either way; this single case just isn't distinguishing
      // under root's own semantics.
      return
    }
    #expect(!UInputPermissionChecker.isDeviceAccessible(path))
  }

  @Test("A nonexistent path is reported inaccessible")
  func missingPathIsNotAccessible() {
    let path = "/nonexistent/\(UUID().uuidString)/uinput"
    #expect(!UInputPermissionChecker.isDeviceAccessible(path))
  }

  // MARK: - groupMembers(named:) / isCurrentUser(inGroup:) — real getgrnam(3)

  @Test("A group name that doesn't exist on this system returns nil members")
  func unknownGroupReturnsNilMembers() {
    let unknownGroup = "clipnest-test-nonexistent-group-\(UUID().uuidString.prefix(8))"
    #expect(UInputPermissionChecker.groupMembers(named: unknownGroup) == nil)
  }

  @Test("isCurrentUser(inGroup:) is false for a group that doesn't exist")
  func isCurrentUserFalseForUnknownGroup() {
    let unknownGroup = "clipnest-test-nonexistent-group-\(UUID().uuidString.prefix(8))"
    #expect(!UInputPermissionChecker.isCurrentUser(inGroup: unknownGroup))
  }

  @Test("currentUsername() resolves to a real, non-empty name")
  func currentUsernameResolves() {
    #expect(!(UInputPermissionChecker.currentUsername() ?? "").isEmpty)
  }

  // MARK: - currentStatus(devicePath:groupName:) — the composed status

  @Test("currentStatus composes both independent checks correctly")
  func currentStatusComposesBothChecks() throws {
    let writablePath = try makeTempFile(permissions: 0o644)
    defer { try? FileManager.default.removeItem(atPath: writablePath) }
    let unknownGroup = "clipnest-test-nonexistent-group-\(UUID().uuidString.prefix(8))"

    let status = UInputPermissionChecker.currentStatus(
      devicePath: writablePath, groupName: unknownGroup)
    #expect(status.isUInputAccessible)
    #expect(!status.isInClipnestInputGroup)
  }

  @Test("The shipped device path and group name constants match the packaging scripts")
  func constantsMatchPackaging() {
    #expect(UInputPermissionChecker.defaultDevicePath == "/dev/uinput")
    #expect(UInputPermissionChecker.grantedGroupName == "clipnest-input")
  }

  // MARK: - Fixture helper

  private func makeTempFile(permissions: Int16) throws -> String {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("uinput-permission-checker-test-\(UUID().uuidString)")
      .path
    FileManager.default.createFile(
      atPath: path, contents: Data(),
      attributes: [.posixPermissions: permissions])
    return path
  }
}
