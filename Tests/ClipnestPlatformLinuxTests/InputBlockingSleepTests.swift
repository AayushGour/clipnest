import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("BlockingSleep")
struct BlockingSleepTests {
  @Test("converts milliseconds to microseconds")
  func convertsMilliseconds() {
    #expect(BlockingSleep.microseconds(for: .milliseconds(10)) == 10_000)
    #expect(BlockingSleep.microseconds(for: .milliseconds(400)) == 400_000)
  }

  @Test("converts sub-millisecond durations")
  func convertsMicroseconds() {
    #expect(BlockingSleep.microseconds(for: .microseconds(250)) == 250)
  }

  @Test("zero duration converts to zero")
  func zeroDuration() {
    #expect(BlockingSleep.microseconds(for: .zero) == 0)
  }

  @Test("clamps rather than overflowing on an absurdly large duration")
  func clampsLargeDuration() {
    #expect(BlockingSleep.microseconds(for: .seconds(10_000)) == UInt32.max)
  }
}
