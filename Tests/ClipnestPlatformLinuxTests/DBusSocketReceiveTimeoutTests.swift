import Foundation
import Testing

@testable import ClipnestPlatformLinux

#if canImport(Glibc)
  import Glibc
#endif

#if canImport(Glibc)
  /// `DBusSocketReceiveTimeout.timeval(for:)` is pure — no socket, no
  /// syscall — so unlike `DBusConnection` itself (manual-verify-only, no
  /// real D-Bus daemon in CI) it is unit tested directly, matching this
  /// module's existing pattern for `DBusConnection`'s other pure
  /// collaborators (`DBusAddress`, `DBusAuthHandshake`).
  @Suite("DBusSocketReceiveTimeout.timeval(for:) — pure Duration -> timeval conversion")
  struct DBusSocketReceiveTimeoutTimevalTests {
    @Test("a whole-second duration converts with zero microseconds")
    func wholeSeconds() {
      let tv = DBusSocketReceiveTimeout.timeval(for: .seconds(2))
      #expect(tv.tv_sec == 2)
      #expect(tv.tv_usec == 0)
    }

    @Test("a sub-second duration converts to microseconds with zero seconds")
    func subSecondMilliseconds() {
      let tv = DBusSocketReceiveTimeout.timeval(for: .milliseconds(500))
      #expect(tv.tv_sec == 0)
      #expect(tv.tv_usec == 500_000)
    }

    @Test("seconds and microseconds both carry through for a mixed duration")
    func mixedSecondsAndMicroseconds() {
      let tv = DBusSocketReceiveTimeout.timeval(for: .seconds(1) + .microseconds(1))
      #expect(tv.tv_sec == 1)
      #expect(tv.tv_usec == 1)
    }

    @Test(
      "a literal zero duration stays all-zero — matches SO_RCVTIMEO's existing block-indefinitely contract"
    )
    func literalZeroStaysZero() {
      let tv = DBusSocketReceiveTimeout.timeval(for: .zero)
      #expect(tv.tv_sec == 0)
      #expect(tv.tv_usec == 0)
    }

    @Test(
      "a positive but sub-microsecond duration is clamped to 1 microsecond, never truncated to all-zero"
    )
    func subMicrosecondDurationIsClampedNotTruncated() {
      // 500ns = 0.5us: `attoseconds / 1_000_000_000_000` truncates this to
      // 0 without the clamp — and an all-zero `timeval` means "block
      // forever" to `SO_RCVTIMEO` (setsockopt(7)), the opposite of what a
      // positive, about-to-expire duration should produce. This is the
      // exact scenario `receiveOneMessageWithFileDescriptors` can hit on
      // its last `recvmsg` round before a deadline.
      let tv = DBusSocketReceiveTimeout.timeval(for: .nanoseconds(500))
      #expect(tv.tv_sec == 0)
      #expect(tv.tv_usec == 1)
    }

    @Test("the smallest representable positive duration is also clamped to 1 microsecond")
    func oneNanosecondIsClamped() {
      let tv = DBusSocketReceiveTimeout.timeval(for: .nanoseconds(1))
      #expect(tv.tv_sec == 0)
      #expect(tv.tv_usec == 1)
    }
  }

  /// Proves the OS-level mechanism `DBusConnection`'s per-call timeout fix
  /// depends on, over a real `AF_UNIX` `socketpair(2)` — no D-Bus daemon
  /// involved (see `DBusFileDescriptorPassingTests`'s doc comment for why
  /// that makes this runnable as an ordinary automated `swift test`).
  /// `DBusConnection` cannot be driven directly here (`init` is
  /// intentionally `private` — see its own doc comment), so these tests
  /// exercise the exact `setsockopt(SO_RCVTIMEO)`-then-`recvmsg` sequence
  /// `receiveOneMessageWithFileDescriptors` performs, standing in for it.
  @Suite("DBusSocketReceiveTimeout.apply — real socketpair, real SO_RCVTIMEO")
  struct DBusSocketReceiveTimeoutApplyTests {
    @Test("a short timeout applied to an idle socket bounds a blocking recvmsg near that value")
    func shortTimeoutBoundsBlockingReceive() {
      let (sender, receiver) = makeUnixSocketPair()
      defer {
        close(sender)
        close(receiver)
      }
      DBusSocketReceiveTimeout.apply(.milliseconds(100), toFileDescriptor: receiver)

      let start = ContinuousClock.now
      let result = DBusFileDescriptorPassing.receive(socket: receiver, maxBytes: 64)
      let elapsed = ContinuousClock.now - start

      #expect(result == nil, "nothing was ever sent — recvmsg must time out, not hang")
      #expect(
        elapsed < .seconds(2),
        "a 100ms SO_RCVTIMEO must bound the blocking recvmsg call, not leave it hanging")
    }

    @Test(
      "re-applying a SHORT timeout after an earlier LONG one overrides it — the exact stale-timeout bug this fix closes"
    )
    func laterShorterTimeoutOverridesEarlierLongerOne() {
      let (sender, receiver) = makeUnixSocketPair()
      defer {
        close(sender)
        close(receiver)
      }
      // Mirrors the pre-fix world: a big CONNECT timeout is applied once...
      DBusSocketReceiveTimeout.apply(.seconds(30), toFileDescriptor: receiver)
      // ...then a much shorter PER-CALL timeout must actually take effect,
      // not be silently shadowed by the earlier, larger value.
      DBusSocketReceiveTimeout.apply(.milliseconds(100), toFileDescriptor: receiver)

      let start = ContinuousClock.now
      let result = DBusFileDescriptorPassing.receive(socket: receiver, maxBytes: 64)
      let elapsed = ContinuousClock.now - start

      #expect(result == nil)
      #expect(
        elapsed < .seconds(2),
        """
        the LATER, shorter timeout must govern — a value anywhere near the stale 30s one \
        would mean every per-call timeout in this codebase is still advisory
        """)
    }

    @Test(
      "a sub-microsecond remaining duration still returns promptly instead of blocking forever"
    )
    func subMicrosecondTimeoutDoesNotBlockForever() {
      let (sender, receiver) = makeUnixSocketPair()
      defer {
        close(sender)
        close(receiver)
      }
      // The exact edge `timeval(for:)`'s clamp exists for: the last sliver
      // of an about-to-expire per-call deadline, rounded to sub-microsecond
      // by the time `receiveOneMessageWithFileDescriptors` applies it.
      DBusSocketReceiveTimeout.apply(.nanoseconds(1), toFileDescriptor: receiver)

      let start = ContinuousClock.now
      let result = DBusFileDescriptorPassing.receive(socket: receiver, maxBytes: 64)
      let elapsed = ContinuousClock.now - start

      #expect(result == nil)
      #expect(
        elapsed < .seconds(2),
        """
        a naively-truncated all-zero timeval would make SO_RCVTIMEO mean "block \
        indefinitely" — the clamp in timeval(for:) exists to prevent exactly that
        """)
    }
  }
#endif
