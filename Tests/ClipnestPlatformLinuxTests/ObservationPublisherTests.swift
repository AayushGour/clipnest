// ObservationPublisherTests.swift
//
// P10-D (Linux port, GTK4 view layer): exercises `ClipnestObservation`'s
// REAL `ObservableObjectPublisher`/`ObservationCancellable` — the fix for
// the two defects that module's doc comment describes: `send()` used to be
// an explicit no-op, and the protocol's default `objectWillChange` used to
// hand back a BRAND NEW instance on every access, so even a working
// `send()` could never reach a subscriber. `PickerWindow`
// (`Sources/ClipnestGTK/Window/PickerWindow+Reconcile.swift`) now
// subscribes to this directly to replace its former 33ms poll loop — these
// are the pure, GTK-independent guarantees that replacement depends on.
//
// `ObservationTestSubject` below mirrors exactly the pattern
// `PickerViewModel.swift` now uses (a STORED `objectWillChange`, since this
// protocol deliberately provides no default — see its doc comment) rather
// than reaching into `PickerViewModel` itself, which would drag in the
// whole `ClipStore`/`SnippetStore`/`Paster` construction this test has no
// interest in. See `GTKKeyEventMappingTests.swift`'s top doc comment for
// this module's shared `ClipnestPlatformLinuxTests` -> transitive-module
// import note (`ClipnestObservation` is reachable here the same way
// `ClipnestViewModels` already is: built into the graph as a dependency of
// `ClipnestGTK` -> `ClipnestViewModels`, not a direct declared dependency of
// this test target).
import ClipnestObservation
import Testing

@MainActor
private final class ObservationTestSubject: ObservableObject {
  let objectWillChange = ObservableObjectPublisher()

  @Published var counter = 0
  @Published var label = ""
}

@MainActor
@Suite("ObservableObjectPublisher")
struct ObservationPublisherTests {
  @Test("objectWillChange returns the SAME instance across accesses")
  func stableIdentityAcrossAccesses() async {
    let subject = ObservationTestSubject()
    let first = subject.objectWillChange
    let second = subject.objectWillChange
    #expect(first === second)
  }

  @Test("subscribing then mutating a @Published property fires the subscriber")
  func subscribeThenMutateFires() async {
    let subject = ObservationTestSubject()
    var fireCount = 0
    let cancellable = subject.objectWillChange.subscribe { fireCount += 1 }
    subject.counter = 1
    #expect(fireCount == 1)
    cancellable.cancel()
  }

  @Test(
    "multiple @Published mutations each notify the subscriber once -- the publisher itself does NOT coalesce (PickerWindowRefreshCoalescer does, on the GTK side)"
  )
  func eachMutationNotifiesSeparately() async {
    let subject = ObservationTestSubject()
    var fireCount = 0
    let cancellable = subject.objectWillChange.subscribe { fireCount += 1 }
    subject.counter = 1
    subject.label = "a"
    subject.counter = 2
    #expect(fireCount == 3)
    cancellable.cancel()
  }

  @Test("cancel() stops further delivery")
  func cancelStopsDelivery() async {
    let subject = ObservationTestSubject()
    var fireCount = 0
    let cancellable = subject.objectWillChange.subscribe { fireCount += 1 }
    subject.counter = 1
    cancellable.cancel()
    subject.counter = 2
    #expect(fireCount == 1)
  }

  @Test("dropping every reference to the cancellation handle also stops delivery, via deinit")
  func deinitCancelsAutomatically() async {
    let subject = ObservationTestSubject()
    var fireCount = 0
    do {
      let cancellable = subject.objectWillChange.subscribe { fireCount += 1 }
      _ = cancellable
    }
    subject.counter = 1
    #expect(fireCount == 0)
  }

  @Test("two independent subscribers both fire")
  func multipleSubscribersBothFire() async {
    let subject = ObservationTestSubject()
    var firstCount = 0
    var secondCount = 0
    let first = subject.objectWillChange.subscribe { firstCount += 1 }
    let second = subject.objectWillChange.subscribe { secondCount += 1 }
    subject.counter = 1
    #expect(firstCount == 1)
    #expect(secondCount == 1)
    first.cancel()
    second.cancel()
  }
}
