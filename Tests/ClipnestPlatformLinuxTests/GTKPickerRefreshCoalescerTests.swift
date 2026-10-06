// GTKPickerRefreshCoalescerTests.swift
//
// P10-D (Linux port, GTK4 view layer): exercises
// `PickerWindowRefreshCoalescer` — the decision of whether a NEW GTK idle
// source needs scheduling for a batch of `PickerViewModel.objectWillChange`
// notifications, or whether one is already pending and this notification
// should fold into it for free. `PickerWindow+Reconcile.swift`'s
// `scheduleCoalescedRefresh()` is the untestable GTK edge that actually
// calls `g_idle_add_full`, driven by this pure state machine — see that
// type's doc comment. See `GTKKeyEventMappingTests.swift`'s top doc comment
// for this module's shared `ClipnestPlatformLinuxTests` -> `ClipnestGTK`
// manifest-dependency note.
import Testing

@testable import ClipnestGTK

@Suite("PickerWindowRefreshCoalescer")
struct GTKPickerRefreshCoalescerTests {
  @Test("the first notification in a turn requests a refresh")
  func firstNotificationRequestsRefresh() {
    let coalescer = PickerWindowRefreshCoalescer()
    #expect(coalescer.beginRefreshIfNeeded() == true)
  }

  @Test("N notifications arriving before the refresh starts produce exactly ONE request")
  func multipleNotificationsCoalesceToOneRequest() {
    let coalescer = PickerWindowRefreshCoalescer()
    var scheduledCount = 0
    for _ in 0..<5 where coalescer.beginRefreshIfNeeded() {
      scheduledCount += 1
    }
    #expect(scheduledCount == 1)
  }

  @Test("markRefreshStarted() re-arms the coalescer for the next batch")
  func markRefreshStartedReArms() {
    let coalescer = PickerWindowRefreshCoalescer()
    #expect(coalescer.beginRefreshIfNeeded() == true)
    #expect(coalescer.beginRefreshIfNeeded() == false)

    coalescer.markRefreshStarted()

    #expect(coalescer.beginRefreshIfNeeded() == true)
    #expect(coalescer.beginRefreshIfNeeded() == false)
  }
}
