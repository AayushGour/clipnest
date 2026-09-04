// Heartbeat.swift
//
// The headline metric (T-STRESS1 dimension 2): a `@MainActor` ticker that
// sleeps ~`tickInterval` and records the ACTUAL gap between consecutive
// wake-ups. Under a healthy app, gaps stay close to `tickInterval`
// regardless of what background work is in flight — any real main-actor
// stall (synchronous heavy work, or a scheduler starved by the cooperative
// thread pool being saturated by blocking detached tasks) shows up directly
// as an outlier gap here.
//
// Per the coordinating note: shared-thread-pool contention from OTHER
// processes on this dev machine (unrelated agents' builds, etc.) can also
// spike gaps on a perfectly correct implementation. `main.swift` always
// runs an IDLE baseline heartbeat first and reports it alongside every
// stress scenario's numbers, so a spike can be judged against "what does
// this machine's noise floor look like right now" instead of an absolute
// threshold.
import Foundation

@MainActor
final class Heartbeat {
  private(set) var gapsMs: [Double] = []
  private var task: Task<Void, Never>?
  private let tickInterval: Duration

  init(tickInterval: Duration = .milliseconds(1)) {
    self.tickInterval = tickInterval
  }

  func start() {
    gapsMs = []
    let interval = tickInterval
    task = Task { @MainActor [weak self] in
      let clock = ContinuousClock()
      var last = clock.now
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self else { return }
        let now = clock.now
        let elapsed = now - last
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        self.gapsMs.append(ms)
        last = now
      }
    }
  }

  func stop() async {
    task?.cancel()
    _ = await task?.value
    task = nil
  }

  var count: Int { gapsMs.count }

  var maxGapMs: Double { gapsMs.max() ?? 0 }

  func percentile(_ p: Double) -> Double {
    guard !gapsMs.isEmpty else { return 0 }
    let sorted = gapsMs.sorted()
    let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count) - 1) * p)))
    return sorted[idx]
  }

  var p99GapMs: Double { percentile(0.99) }
  var meanGapMs: Double { gapsMs.isEmpty ? 0 : gapsMs.reduce(0, +) / Double(gapsMs.count) }

  func summary(label: String) -> String {
    String(
      format: "%@: n=%d mean=%.3fms p99=%.3fms max=%.3fms",
      label, count, meanGapMs, p99GapMs, maxGapMs)
  }
}
