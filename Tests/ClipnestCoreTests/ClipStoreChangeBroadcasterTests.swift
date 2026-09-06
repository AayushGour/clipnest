import Foundation
import Testing

@testable import ClipnestCore

@Suite("ClipStoreChangeBroadcaster")
struct ClipStoreChangeBroadcasterTests {

  @Test("send(_:) delivers to a single subscriber")
  func deliversToSingleSubscriber() {
    let broadcaster = ClipStoreChangeBroadcaster()
    let received = Box<[ClipStoreChange]>([])
    let id = UUID()
    let subscription = broadcaster.subscribe { change in received.value.append(change) }
    defer { subscription.cancel() }

    broadcaster.send(.deleted(id))

    #expect(received.value == [.deleted(id)])
  }

  @Test("send(_:) delivers to every current subscriber, in registration order")
  func deliversToEveryCurrentSubscriber() {
    let broadcaster = ClipStoreChangeBroadcaster()
    let receivedA = Box<[ClipStoreChange]>([])
    let receivedB = Box<[ClipStoreChange]>([])
    let subscriptionA = broadcaster.subscribe { receivedA.value.append($0) }
    let subscriptionB = broadcaster.subscribe { receivedB.value.append($0) }
    defer {
      subscriptionA.cancel()
      subscriptionB.cancel()
    }

    broadcaster.send(.clearedAll)

    #expect(receivedA.value == [.clearedAll])
    #expect(receivedB.value == [.clearedAll])
  }

  @Test("Cancelling a subscription's token stops further delivery to it, without affecting others")
  func cancelStopsDelivery() {
    let broadcaster = ClipStoreChangeBroadcaster()
    let receivedA = Box<[ClipStoreChange]>([])
    let receivedB = Box<[ClipStoreChange]>([])
    let subscriptionA = broadcaster.subscribe { receivedA.value.append($0) }
    let subscriptionB = broadcaster.subscribe { receivedB.value.append($0) }
    defer { subscriptionB.cancel() }

    subscriptionA.cancel()
    broadcaster.send(.clearedAll)

    #expect(receivedA.value.isEmpty)
    #expect(receivedB.value == [.clearedAll])
  }

  @Test("Letting a subscription token deallocate stops delivery, same as calling cancel()")
  func deinitStopsDelivery() {
    let broadcaster = ClipStoreChangeBroadcaster()
    let received = Box<[ClipStoreChange]>([])
    do {
      let subscription = broadcaster.subscribe { received.value.append($0) }
      _ = subscription  // keep it alive only for this scope
    }

    broadcaster.send(.clearedAll)

    #expect(received.value.isEmpty)
  }

  @Test("send(_:) with zero subscribers is a safe no-op")
  func sendWithNoSubscribersIsANoOp() {
    let broadcaster = ClipStoreChangeBroadcaster()
    broadcaster.send(.clearedAll)
  }

  @Test("Multiple sends are all delivered, in order")
  func multipleSendsDeliverInOrder() {
    let broadcaster = ClipStoreChangeBroadcaster()
    let received = Box<[ClipStoreChange]>([])
    let subscription = broadcaster.subscribe { received.value.append($0) }
    defer { subscription.cancel() }
    let firstID = UUID()
    let secondID = UUID()

    broadcaster.send(.deleted(firstID))
    broadcaster.send(.updated(secondID))
    broadcaster.send(.clearedAll)
    broadcaster.send(.retentionApplied)

    #expect(
      received.value == [
        .deleted(firstID), .updated(secondID), .clearedAll, .retentionApplied,
      ])
  }
}

/// A tiny mutable reference box so a `@Sendable` subscriber closure can
/// accumulate results across `send(_:)` calls. `@unchecked Sendable`: every
/// test above calls `send(_:)` synchronously, on one thread, so there is no
/// actual concurrent access to police — an actor would be needless ceremony
/// here.
private final class Box<Value>: @unchecked Sendable {
  var value: Value
  init(_ value: Value) { self.value = value }
}
