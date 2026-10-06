import Foundation

/// `Duration` -> `TimeInterval` conversion, needed anywhere this module
/// mixes Swift Concurrency's `Duration` API with a Foundation API that only
/// accepts `TimeInterval`/`Date` (`Thread.sleep(forTimeInterval:)`,
/// `NSCondition.wait(until:)` via `Date.addingTimeInterval`) — kept in ONE
/// place per coding-standards.md's DRY rule now that a second call site
/// needs it: `LinuxAppLifecycle`'s bounded Shell-extension live-dispatch
/// retry (`retryLiveDispatchProbeIfNeeded`), and `ClipnestControlService`'s
/// demuxed outgoing-call wait (`call(_:timeout:)`, T-P10I).
enum DurationConversion {
  static func timeInterval(for duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }
}
