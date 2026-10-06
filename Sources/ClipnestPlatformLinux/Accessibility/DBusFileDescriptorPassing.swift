import Foundation

#if canImport(Glibc)
  import Glibc
#endif

#if canImport(Glibc)
  /// Hand-rolled `sendmsg(2)`/`recvmsg(2)` wrappers that attach real UNIX
  /// file descriptors to a byte stream via `SCM_RIGHTS` ancillary data —
  /// the transport-level mechanism `DBusValue.unixFD`'s wire-format INDEX
  /// depends on (see that case's doc comment: the message body only ever
  /// carries an index into this ancillary array, never the descriptor
  /// itself).
  ///
  /// **Why this needs hand-rolled pointer math, unlike `sendmsg`/`recvmsg`
  /// themselves:** `Glibc.sendmsg`/`Glibc.recvmsg`/`msghdr`/`cmsghdr` all
  /// import into Swift directly and are callable as-is — verified against
  /// the real `swift:6.0-jammy` image this project's CI (`ci.yml`) builds
  /// against: neither function is C-variadic (unlike `ioctl`, see
  /// `UInputDevice.RawIoctl` and decision D59), so no `dlopen`/`dlsym`
  /// workaround is needed for THEM. What genuinely isn't imported is the
  /// `CMSG_*` macro family (`CMSG_FIRSTHDR`, `CMSG_DATA`, `CMSG_LEN`,
  /// `CMSG_SPACE`, `CMSG_ALIGN`) — they're C preprocessor macros built from
  /// pointer casts and `offsetof`-style arithmetic that ClangImporter has
  /// no callable Swift symbol to bridge to. This type reimplements exactly
  /// glibc's own definitions (`bits/socket.h`, read directly out of the
  /// `swift:6.0-jammy` image while building this):
  ///
  /// ```c
  /// #define CMSG_ALIGN(len) (((len) + sizeof(size_t) - 1) & ~(sizeof(size_t) - 1))
  /// #define CMSG_SPACE(len) (CMSG_ALIGN(len) + CMSG_ALIGN(sizeof(struct cmsghdr)))
  /// #define CMSG_LEN(len)   (CMSG_ALIGN(sizeof(struct cmsghdr)) + (len))
  /// #define CMSG_DATA(cmsg) ((unsigned char *)(cmsg) + CMSG_ALIGN(sizeof(struct cmsghdr)))
  /// #define CMSG_FIRSTHDR(mhdr) \
  ///   ((size_t)(mhdr)->msg_controllen >= sizeof(struct cmsghdr) \
  ///    ? (struct cmsghdr *)(mhdr)->msg_control : (struct cmsghdr *)0)
  /// ```
  ///
  /// `sizeof(size_t)` (the alignment `CMSG_ALIGN` rounds to) is
  /// `MemoryLayout<Int>.size` — verified to be 8 on both x86_64 and arm64
  /// Ubuntu (`msg_iovlen`/`msg_controllen`/`cmsg_len` all import as `Int`,
  /// confirmed via a throwaway probe against the real toolchain image, not
  /// assumed), so there is no cross-architecture surprise across this
  /// project's two shipped targets. This module only ever attaches ONE
  /// `cmsghdr` per message (a single `SCM_RIGHTS` block carrying every fd
  /// for that message) — never a chain — so `CMSG_NXTHDR` is never needed.
  enum DBusFileDescriptorPassing {
    /// Generous upper bound on how many descriptors this module will ever
    /// receive attached to ONE message — every real
    /// `app.clipnest.ShellHelper1` method carries at most one `h` argument
    /// (see `extension/dbus/app.clipnest.ShellHelper1.xml`), so this is
    /// headroom against `MSG_CTRUNC`, not an expected count.
    /// `MSG_CTRUNC` matters here because if the ancillary buffer we hand
    /// the kernel is too small, the kernel silently DROPS (closes) the
    /// real descriptors rather than partially delivering them — sizing
    /// generously up front is what keeps every `recvmsg` fd-safe, not
    /// just the "happy path" ones.
    static let maxFileDescriptorsPerMessage = 16

    private static let sizeOfCMsgHdr = MemoryLayout<cmsghdr>.size
    /// `sizeof(size_t)` — see this type's doc comment.
    private static let alignment = MemoryLayout<Int>.size

    private static func cmsgAlign(_ length: Int) -> Int {
      (length + alignment - 1) & ~(alignment - 1)
    }

    private static func cmsgSpace(_ length: Int) -> Int {
      cmsgAlign(length) + cmsgAlign(sizeOfCMsgHdr)
    }

    private static func cmsgLen(_ length: Int) -> Int {
      cmsgAlign(sizeOfCMsgHdr) + length
    }

    /// Writes `bytes` to `socket`, attaching `fileDescriptors` (if any) as
    /// a single `SCM_RIGHTS` ancillary block on the SAME `sendmsg(2)` call.
    /// The two MUST travel together in one syscall: per `unix(7)`,
    /// ancillary data rides with whichever bytes the kernel delivers to
    /// the peer's FIRST `recvmsg` covering this call's data — attaching
    /// the fds to a later, separate write would let the receiver associate
    /// them with the wrong (or no) bytes.
    ///
    /// Falls back to a plain `write(2)` when `fileDescriptors` is empty —
    /// this is what every non-fd-carrying `DBusConnection` send already
    /// did before this type existed, unchanged.
    static func send(socket: Int32, bytes: [UInt8], fileDescriptors: [Int32]) -> Bool {
      guard !fileDescriptors.isEmpty else {
        return bytes.withUnsafeBytes { rawBuffer in
          guard let baseAddress = rawBuffer.baseAddress else { return bytes.isEmpty }
          return Glibc.write(socket, baseAddress, rawBuffer.count) == rawBuffer.count
        }
      }

      let controlLength = cmsgSpace(fileDescriptors.count * MemoryLayout<Int32>.size)
      var controlBuffer = [UInt8](repeating: 0, count: controlLength)

      return bytes.withUnsafeBytes { bodyBuffer -> Bool in
        controlBuffer.withUnsafeMutableBytes { controlRaw -> Bool in
          guard let controlBase = controlRaw.baseAddress else { return false }
          let cmsg = controlBase.assumingMemoryBound(to: cmsghdr.self)
          cmsg.pointee.cmsg_len = cmsgLen(fileDescriptors.count * MemoryLayout<Int32>.size)
          cmsg.pointee.cmsg_level = SOL_SOCKET
          cmsg.pointee.cmsg_type = Int32(SCM_RIGHTS)
          // CMSG_DATA(cmsg): the payload starts right after the (aligned)
          // fixed-size cmsghdr header, NOT after `MemoryLayout<cmsghdr>
          // .size` naively — those coincide here (16 is already 8-aligned)
          // but computing it via `cmsgAlign` is what stays correct if a
          // future glibc ever changes `cmsghdr`'s fixed-field size.
          let dataStart = controlBase.advanced(by: cmsgAlign(sizeOfCMsgHdr))
          dataStart.withMemoryRebound(to: Int32.self, capacity: fileDescriptors.count) {
            fdPointer in
            for (index, fd) in fileDescriptors.enumerated() { fdPointer[index] = fd }
          }

          var iov = iovec(
            iov_base: UnsafeMutableRawPointer(mutating: bodyBuffer.baseAddress),
            iov_len: bodyBuffer.count)
          var message = msghdr()
          let sentByteCount = withUnsafeMutablePointer(to: &iov) { iovPointer -> Int in
            message.msg_name = nil
            message.msg_namelen = 0
            message.msg_iov = iovPointer
            message.msg_iovlen = 1
            message.msg_control = controlBase
            message.msg_controllen = controlLength
            message.msg_flags = 0
            return withUnsafeMutablePointer(to: &message) { messagePointer in
              Glibc.sendmsg(socket, messagePointer, 0)
            }
          }
          return sentByteCount == bodyBuffer.count
        }
      }
    }

    /// Reads one `recvmsg(2)`'s worth of bytes (up to `maxBytes`) off
    /// `socket`, always supplying a `maxFileDescriptorsPerMessage`-sized
    /// ancillary buffer so an `SCM_RIGHTS` block is never silently
    /// truncated even on a call the caller didn't expect fds from.
    ///
    /// - Returns: `nil` on error/EOF (`recvmsg` returned `<= 0`), matching
    ///   `Glibc.read`'s existing failure contract elsewhere in this
    ///   module. On success, `fileDescriptors` are REAL, now-open
    ///   descriptors this process owns from this call onward — the caller
    ///   MUST close every one exactly once (see `DBusConnection`'s
    ///   `pendingFileDescriptors` handling for how this module discharges
    ///   that duty deterministically rather than leaking).
    static func receive(socket: Int32, maxBytes: Int) -> (bytes: [UInt8], fileDescriptors: [Int32])?
    {
      let controlLength = cmsgSpace(maxFileDescriptorsPerMessage * MemoryLayout<Int32>.size)
      var controlBuffer = [UInt8](repeating: 0, count: controlLength)
      var dataBuffer = [UInt8](repeating: 0, count: maxBytes)
      var collectedFileDescriptors: [Int32] = []

      let readCount = dataBuffer.withUnsafeMutableBytes { dataRaw -> Int in
        controlBuffer.withUnsafeMutableBytes { controlRaw -> Int in
          var iov = iovec(iov_base: dataRaw.baseAddress, iov_len: dataRaw.count)
          var message = msghdr()
          return withUnsafeMutablePointer(to: &iov) { iovPointer -> Int in
            message.msg_name = nil
            message.msg_namelen = 0
            message.msg_iov = iovPointer
            message.msg_iovlen = 1
            message.msg_control = controlRaw.baseAddress
            message.msg_controllen = controlRaw.count
            message.msg_flags = 0
            let result = withUnsafeMutablePointer(to: &message) { messagePointer in
              Glibc.recvmsg(socket, messagePointer, 0)
            }
            guard result > 0 else { return result }
            collectedFileDescriptors = extractFileDescriptors(
              fromControl: controlRaw, controlLengthUsed: message.msg_controllen)
            return result
          }
        }
      }

      guard readCount > 0 else { return nil }
      return (Array(dataBuffer.prefix(readCount)), collectedFileDescriptors)
    }

    /// `CMSG_FIRSTHDR` + a single `SCM_RIGHTS` payload walk — this module
    /// never attaches more than one `cmsghdr`, so unlike a general-purpose
    /// ancillary-data reader this deliberately does NOT loop via
    /// `CMSG_NXTHDR`.
    private static func extractFileDescriptors(
      fromControl controlRaw: UnsafeMutableRawBufferPointer, controlLengthUsed: Int
    ) -> [Int32] {
      // CMSG_FIRSTHDR: no header at all unless the kernel actually wrote
      // at least one full `cmsghdr`.
      guard controlLengthUsed >= sizeOfCMsgHdr, let base = controlRaw.baseAddress else { return [] }
      let cmsg = base.assumingMemoryBound(to: cmsghdr.self)
      guard cmsg.pointee.cmsg_level == SOL_SOCKET, cmsg.pointee.cmsg_type == Int32(SCM_RIGHTS)
      else { return [] }
      let headerLength = cmsgAlign(sizeOfCMsgHdr)
      let payloadLength = cmsg.pointee.cmsg_len - headerLength
      guard payloadLength > 0 else { return [] }
      let fileDescriptorCount = payloadLength / MemoryLayout<Int32>.size
      let dataStart = base.advanced(by: headerLength)  // CMSG_DATA
      return dataStart.withMemoryRebound(to: Int32.self, capacity: fileDescriptorCount) {
        fdPointer in
        (0..<fileDescriptorCount).map { fdPointer[$0] }
      }
    }
  }
#endif
