import Foundation

#if canImport(Glibc)
  import Glibc
#endif

#if canImport(Glibc)
  /// Converts a `Duration` into the `timeval` `SO_RCVTIMEO` expects and
  /// applies it to a socket file descriptor.
  ///
  /// Extracted out of `DBusConnection` (which used to inline this as a
  /// private `applyTimeout`, called exactly once, at `connect()` time) so
  /// it can be applied AGAIN — per call, per `recvmsg` round — from
  /// `receiveOneMessageWithFileDescriptors(timeout:)` without duplicating
  /// the conversion logic. Also lets the one genuinely PURE piece of this
  /// mechanism (`timeval(for:)`) be unit tested directly, matching this
  /// module's existing pattern for `DBusConnection`'s other collaborators:
  /// `DBusConnection` itself stays manual-verify-only (no real D-Bus daemon
  /// in CI — see its own doc comment), while `DBusAddress`,
  /// `DBusAuthHandshake`, and now this, carry the automated coverage.
  enum DBusSocketReceiveTimeout {
    /// Builds the `timeval` for `duration`.
    ///
    /// Clamped so a duration that is POSITIVE but rounds down to an
    /// all-zero `timeval` — sub-microsecond, e.g. the last sliver of an
    /// about-to-expire per-call deadline — is bumped up to the smallest
    /// representable non-zero timeout (1 microsecond) instead of being
    /// truncated to a literal zero.
    ///
    /// **Why this matters, concretely:** per `setsockopt(7)`, an all-zero
    /// `SO_RCVTIMEO` timeval means "block indefinitely" — the OPPOSITE of
    /// what an about-to-expire deadline should produce. Before this type
    /// existed, `DBusConnection` only ever applied a caller-supplied
    /// CONNECT timeout once, at connection setup — always a normal,
    /// multi-millisecond-or-larger value in practice, so this edge never
    /// came up. Once each `recvmsg` round applies the call's REMAINING
    /// time (see `DBusConnection.receiveOneMessageWithFileDescriptors`),
    /// that remaining value can legitimately be smaller than one
    /// microsecond on the final round before a deadline — truncating that
    /// to zero would silently turn "give up now" into "wait forever", a
    /// worse bug than the stale-timeout one this type exists to fix. A
    /// literal zero `duration` itself is left alone (still means "block
    /// indefinitely") — nothing in this codebase passes `.zero` on
    /// purpose, and preserving that mapping keeps `connect(address:
    /// timeout:)`'s existing contract unchanged for any caller that did.
    static func timeval(for duration: Duration) -> Glibc.timeval {
      var tv = Glibc.timeval()
      // `.init(...)` rather than a direct assignment: `timeval.tv_sec`/
      // `.tv_usec`'s exact imported integer type (`Int` vs `Int32`, per the
      // platform's `time_t`/`suseconds_t` width) isn't something this file
      // hardcodes an assumption about — `BinaryInteger.init(_:)` converts
      // from `Duration.components`' `Int64` fields to whatever that type
      // actually is.
      tv.tv_sec = .init(duration.components.seconds)
      tv.tv_usec = .init(duration.components.attoseconds / 1_000_000_000_000)
      if tv.tv_sec == 0 && tv.tv_usec == 0 && duration > .zero {
        tv.tv_usec = 1
      }
      return tv
    }

    /// Applies `duration` as `SO_RCVTIMEO` on `fd` — the syscall half, not
    /// unit tested directly for the same reason the rest of
    /// `DBusConnection`'s socket code isn't (needs a live fd to observe any
    /// effect); proven instead by `DBusFileDescriptorPassingTests`' real
    /// `socketpair(2)` timing tests, which exercise this exact
    /// `setsockopt`-then-`recvmsg` mechanism end to end.
    static func apply(_ duration: Duration, toFileDescriptor fd: Int32) {
      var tv = timeval(for: duration)
      withUnsafeBytes(of: &tv) { rawBuffer in
        _ = Glibc.setsockopt(
          fd, SOL_SOCKET, SO_RCVTIMEO, rawBuffer.baseAddress, socklen_t(rawBuffer.count))
      }
    }
  }
#endif
