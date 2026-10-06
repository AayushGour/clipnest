import Foundation
import Testing

@testable import ClipnestGTK
@testable import ClipnestLinuxAppKit

/// T-OPT3: `GrantInputHelperClient` is the ONE call site that invokes the
/// existing, already-scoped privileged helper via `pkexec` — see that
/// type's own doc comment. `pkexecArguments(helperPath:)` is pure and
/// unit-tested directly (mirrors `UpdateChecker.curlArguments(for:)`'s
/// identical split); `requestGrant(completion:)` itself spawns a real
/// process, which this bare container CAN exercise meaningfully: it has no
/// `/usr/bin/pkexec` at all (confirmed: `which pkexec` exits 1), so this is
/// a real, honest exercise of the "pkexec unavailable" failure path this
/// task's own verification calls out — not a mock.
@Suite("GrantInputHelperClient")
struct AppGrantInputHelperClientTests {
  @Test("pkexecArguments invokes exactly the helper path, no extra arguments")
  func pkexecArgumentsIsJustTheHelperPath() {
    #expect(
      GrantInputHelperClient.pkexecArguments(helperPath: "/usr/libexec/clipnest/x") == [
        "/usr/libexec/clipnest/x"
      ])
  }

  @Test("The shipped constants match the packaging scripts/policy")
  func constantsMatchPackaging() {
    #expect(GrantInputHelperClient.helperPath == "/usr/libexec/clipnest/clipnest-grant-input")
    #expect(GrantInputHelperClient.pkexecExecutablePath == "/usr/bin/pkexec")
  }

  @Test(
    "requestGrant(completion:) reports a real failure — never hangs, never crashes — when pkexec isn't installed"
  )
  func requestGrantSurfacesMissingPkexecAsFailure() async throws {
    // Guarded rather than assumed: this project's own bare build/test
    // container genuinely has no /usr/bin/pkexec (verified via `which`
    // before writing this test), which is what makes this a real exercise
    // of `Process.run()`'s throw path rather than a simulated one — but a
    // DIFFERENT CI environment that happens to have pkexec installed (with
    // no authentication agent registered) would instead exercise pkexec's
    // own fail-fast-without-an-agent path, which this test cannot assume
    // completes quickly or produces a non-empty stderr on every polkit
    // build. Skips rather than risks a flaky/hanging assertion on a
    // machine this test doesn't control.
    guard !FileManager.default.fileExists(atPath: GrantInputHelperClient.pkexecExecutablePath)
    else { return }

    let outcome = await withCheckedContinuation {
      (continuation: CheckedContinuation<UInputGrantOutcome, Never>) in
      GrantInputHelperClient.requestGrant { outcome in
        continuation.resume(returning: outcome)
      }
    }
    switch outcome {
    case .succeeded:
      Issue.record("Expected failure — no pkexec is installed in this test environment")
    case .failed(let message):
      #expect(!message.isEmpty)
    }
  }
}
