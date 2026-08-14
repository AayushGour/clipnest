// AsyncWaiting.swift
//
// `PickerViewModel`'s query pipelines are real, async `Task`-driven work
// (see that file's top doc comment) even when a trigger isn't debounced —
// `willShow()`/an `activeTab` change schedules a `Task` that hasn't
// necessarily run by the time the call that scheduled it returns. Rather
// than a fixed `Task.sleep` (slow, and still technically racy under load),
// this polls the MainActor's own run loop via `Task.yield()` until
// `condition` holds or `timeout` elapses — bounded, so a genuinely-stuck
// condition still fails fast instead of hanging the suite, but normally
// resolves after a handful of yields since every fetch here is a same-
// process, in-memory `actor` round trip (no real I/O, no debounce sleep for
// any non-debounced trigger).
import Foundation
import Testing

@MainActor
func waitUntil(
  timeout: Duration = .seconds(2),
  _ condition: @MainActor () -> Bool
) async {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return }
    await Task.yield()
  }
  // Let the caller's own `#expect(condition())` (always called right after
  // `waitUntil` in this suite) produce the actual failure with a useful
  // diff — this is just the timeout backstop.
}
