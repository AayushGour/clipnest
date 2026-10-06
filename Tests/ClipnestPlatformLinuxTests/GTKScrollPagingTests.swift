// GTKScrollPagingTests.swift
//
// P7-D (Linux port, GTK4 view layer). See GTKKeyEventMappingTests.swift's
// top doc comment for the `ClipnestPlatformLinuxTests` -> `ClipnestGTK`
// manifest-dependency note that applies to every `GTK*Tests.swift` file.
import Testing

@testable import ClipnestGTK

@Suite("ScrollPaging")
struct GTKScrollPagingTests {
  @Test("Far from the bottom does not load more")
  func farFromBottomDoesNotLoad() {
    #expect(!ScrollPaging.shouldLoadMore(value: 0, pageSize: 400, upper: 4000))
  }

  @Test("Exactly at the threshold distance loads more")
  func exactlyAtThresholdLoads() {
    // upper - (value + pageSize) == loadMoreThresholdPixels exactly.
    let upper = 1000.0
    let pageSize = 400.0
    let value = upper - pageSize - ScrollPaging.loadMoreThresholdPixels
    #expect(ScrollPaging.shouldLoadMore(value: value, pageSize: pageSize, upper: upper))
  }

  @Test("Scrolled all the way to the bottom loads more")
  func atBottomLoads() {
    #expect(ScrollPaging.shouldLoadMore(value: 600, pageSize: 400, upper: 1000))
  }

  @Test("A degenerate (zero/negative) adjustment never loads more")
  func degenerateAdjustmentNeverLoads() {
    #expect(!ScrollPaging.shouldLoadMore(value: 0, pageSize: 0, upper: 0))
    #expect(!ScrollPaging.shouldLoadMore(value: 0, pageSize: 0, upper: -10))
  }

  @Test("Content shorter than the viewport (upper <= pageSize) still loads more")
  func contentShorterThanViewportLoads() {
    #expect(ScrollPaging.shouldLoadMore(value: 0, pageSize: 400, upper: 300))
  }
}
