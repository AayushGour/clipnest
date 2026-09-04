// Recorders.swift
//
// Small `@unchecked Sendable` recorder classes, exactly mirroring
// `ClipboardMonitorTests.swift`'s `CaptureFailureRecorder`/`MutableBox`
// pattern (a bound instance method passed as the closure, e.g.
// `recorder.handle`, rather than a closure literal capturing a mutable
// local `var` — which Swift 6 strict concurrency correctly rejects for a
// `@Sendable` closure type like `ClipboardMonitor.CaptureFailureHandler`).
// Safe here for the same documented reason that precedent gives: every use
// in this harness only ever calls `handle`/reads `value` sequentially from
// the driving `@MainActor` scenario function — never concurrently.
import Foundation

final class FailureRecorder: @unchecked Sendable {
  private(set) var lastError: Error?
  private(set) var callCount = 0

  func handle(_ error: Error) {
    lastError = error
    callCount += 1
  }

  var wasCalled: Bool { callCount > 0 }
}

final class MutableBox<Value: Sendable>: @unchecked Sendable {
  var value: Value
  init(_ value: Value) { self.value = value }
}
