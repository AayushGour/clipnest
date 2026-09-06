// ObservableObject.swift
//
// Phase 3 (Linux port), P5: `Combine` does not exist on Linux (verified
// empirically in a `swift:6.0-jammy` container — `import Combine` fails with
// "no such module 'Combine'"), but `PickerViewModel` (being extracted into
// `ClipnestViewModels` for reuse by the future Linux GTK app) is an
// `ObservableObject` with ~12 `@Published` properties. Migrating it to
// `Observation`'s `@Observable` (which DOES exist on Linux) was explicitly
// rejected for this task: it would change SwiftUI re-render semantics in the
// shipping macOS app (a behavior-freeze violation), and pulling in
// OpenCombine as a third-party dependency was rejected too (this repo's
// dependency policy — coding-standards.md — allows exactly one third-party
// package, `KeyboardShortcuts`, and it's `ClipnestApp`-only).
//
// This module is the minimal, Combine-API-shaped stand-in that lets
// `PickerViewModel.swift` compile unchanged (module-and-behavior-wise) on
// Linux via exactly one conditional import:
//
//   #if canImport(Combine)
//     import Combine
//   #else
//     import ClipnestObservation
//   #endif
//
// On every Apple platform `canImport(Combine)` is true, so this module's
// entire contents below are compiled out (`#if !canImport(Combine)`) and it
// exports zero public symbols there — the real `Combine.ObservableObject`/
// `Combine.Published`/`Combine.ObservableObjectPublisher` are used instead,
// completely unchanged from before this extraction.
//
// P10-D (Linux port, GTK4 view layer): this file originally shipped
// `ObservableObjectPublisher.send()` as an explicit no-op, with a default
// `objectWillChange` that returned a BRAND NEW instance on every access —
// sound only because nothing in this codebase subscribed to either one at
// the time (P7-D's `PickerWindow` instead polled `PickerViewModel`'s
// `@Published` state on a 33ms `GLib` timeout — see
// `PickerWindow+Polling.swift`'s history). That poll loop is gone: this file
// now implements a REAL, minimal pub/sub, and `PickerWindow`
// (`Sources/ClipnestGTK/Window/PickerWindow.swift`) subscribes to it
// directly. Two defects had to be fixed to get there:
//
//  1. `send()` did nothing — fixed below: it now invokes every currently
//     registered subscriber, synchronously, in `subscribe(_:)`'s
//     registration order.
//  2. The default `objectWillChange` handed back a fresh
//     `ObservableObjectPublisher` on every read, so even a working `send()`
//     could never reach a subscriber that read `objectWillChange` at a
//     different time than the mutation that fired it (which is EVERY real
//     subscriber — you subscribe once, long before the mutation you're
//     waiting for). Real `Combine` avoids this via the Objective-C
//     runtime's associated-object storage, lazily creating exactly one
//     publisher per conforming instance and caching it against that
//     instance's own identity — unavailable on Linux, no Objective-C
//     runtime. Rather than reintroduce the same class of bug with a
//     hand-rolled global `ObjectIdentifier`-keyed side table (whose entries
//     would need their own removal hook to avoid leaking one dictionary
//     entry per `PickerViewModel` for the process's lifetime — a "leak by
//     design" this task's own instructions rule out), this protocol now
//     declares NO default `objectWillChange` implementation at all: every
//     conforming type must store its own instance directly. See
//     `PickerViewModel.swift`'s `objectWillChange` property (declared right
//     on the class, under this same `#if !canImport(Combine)` gate) — this
//     is exactly what the Swift compiler's OWN `@Published` synthesis does
//     automatically, invisibly, on Apple platforms for any type with at
//     least one `@Published` property; this file just does it by hand,
//     since Swift does not synthesize conformances for a protocol it didn't
//     define. A future conformer that forgets this now gets a compiler
//     error ("type does not conform to protocol") instead of silently
//     inheriting a publisher that can never reach a subscriber.
#if !canImport(Combine)

  /// Portable stand-in for `Combine.ObservableObjectPublisher` — see this
  /// file's top doc comment. A real, minimal pub/sub: `subscribe(_:)`
  /// registers a handler and returns a handle to unregister it again;
  /// `send()` invokes every currently-registered handler, synchronously, in
  /// registration order (iteration order isn't otherwise meaningful here —
  /// this codebase has exactly one subscriber, `PickerWindow`, at any given
  /// time, so nothing depends on it). Matches `@Published`'s enclosing-
  /// instance subscript below, which already calls this eagerly, BEFORE the
  /// value it guards actually changes — the same "will change" contract
  /// `Combine`'s real type documents.
  ///
  /// Concurrency: deliberately NOT `@MainActor`-isolated at the type level.
  /// `Published`'s static `_enclosingInstance` subscript below is generic
  /// over `EnclosingSelf: ObservableObject` and is therefore itself
  /// `nonisolated` — the compiler cannot see, generically, that a given
  /// conformer happens to be `@MainActor`. A `@MainActor`-isolated `send()`
  /// cannot be called synchronously from that generic, `nonisolated`
  /// subscript without `await` (confirmed empirically: an `@MainActor`
  /// version of this exact type fails `swiftc -strict-concurrency=complete`
  /// at precisely that call site). Instead, this type documents a single
  /// invariant and relies on it, the same pattern this codebase already
  /// uses for `BlobStore`'s `nonisolated(unsafe)` state and `PickerWindow`'s
  /// `@unchecked Sendable` conformance: every `subscribe`/`send`/cancel call
  /// happens on the ONE thread this whole process's actor-isolated work
  /// runs on. Concretely — `PickerViewModel` (this protocol's only
  /// conformer in this codebase) is `@MainActor`, so every `@Published`
  /// mutation (and therefore every `send()`, called from within that
  /// mutation's own synthesized setter) already runs on `MainActor`'s
  /// executor thread; `PickerWindow` (the only subscriber) documents, in
  /// its own "ACTOR ISOLATION" top doc comment, that the GTK thread IS that
  /// same executor thread for this whole subsystem's lifetime, and already
  /// reaches `PickerViewModel` only through `MainActor.assumeIsolated`
  /// rather than a real cross-thread hop — subscribing/cancelling from that
  /// same context is consistent with that established pattern, not a new
  /// one. `@unchecked Sendable` (upgraded here from the prior, genuinely
  /// stateless `Sendable` conformance, now that this type holds real
  /// mutable subscriber state) records that invariant explicitly rather
  /// than leaving it unstated.
  public final class ObservableObjectPublisher: @unchecked Sendable {
    private var nextSubscriptionID: UInt64 = 0
    private var subscribers: [UInt64: () -> Void] = [:]

    public init() {}

    /// Registers `handler` to run on every future `send()` until the
    /// returned handle is cancelled (explicitly, via `cancel()`, or
    /// implicitly on its `deinit` — see `ObservationCancellable`).
    /// `@discardableResult`: a hypothetical caller meaning to keep a
    /// subscription alive for this publisher's ENTIRE lifetime has no
    /// handle to manage in the first place, and shouldn't be forced to bind
    /// one just to satisfy the type checker — though no such caller exists
    /// in this codebase today; `PickerWindow` always binds and later
    /// cancels its handle (see `PickerWindow.hide()`).
    @discardableResult
    public func subscribe(_ handler: @escaping () -> Void) -> ObservationCancellable {
      nextSubscriptionID += 1
      let id = nextSubscriptionID
      subscribers[id] = handler
      return ObservationCancellable { [weak self] in
        self?.subscribers.removeValue(forKey: id)
      }
    }

    public func send() {
      for handler in subscribers.values {
        handler()
      }
    }
  }

  /// The handle `ObservableObjectPublisher.subscribe(_:)` returns.
  /// `cancel()` unregisters the subscription; letting every reference to
  /// this instance drop without calling `cancel()` has the same effect via
  /// `deinit`, mirroring `Combine.AnyCancellable`'s own auto-cancel-on-
  /// deinit idiom — a caller that simply overwrites its stored handle
  /// (`PickerWindow.hide()` does not do this today; it calls `cancel()`
  /// explicitly, but a future call site that forgot to would still be
  /// safe) doesn't leak the subscription.
  ///
  /// Not `Sendable`, deliberately: nothing in this codebase needs to move a
  /// cancellation handle across a concurrency domain. `PickerWindow` (this
  /// type's only holder) is itself `@unchecked Sendable`, which already
  /// tells the compiler to trust that whole type's thread-safety without
  /// individually checking each stored property — see that type's own doc
  /// comment — so adding an `@unchecked Sendable` claim here too would be
  /// an unnecessary, unenforced promise about a type that never needs to
  /// make one.
  public final class ObservationCancellable {
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
      self.action = action
    }

    public func cancel() {
      action?()
      action = nil
    }

    deinit {
      action?()
    }
  }

  /// Portable stand-in for `Combine.ObservableObject`. Deliberately
  /// declares NO default `objectWillChange` implementation — see this
  /// file's top doc comment (defect #2) for why: every conforming type
  /// (today, only `PickerViewModel`) must declare its own stored
  /// `objectWillChange` publisher directly, so its identity is stable
  /// across accesses. A conformer that omits it fails to compile, rather
  /// than silently inheriting a publisher that can never reach a
  /// subscriber.
  public protocol ObservableObject: AnyObject {
    associatedtype ObjectWillChangePublisher: Sendable = ObservableObjectPublisher
    var objectWillChange: ObjectWillChangePublisher { get }
  }

  /// Portable stand-in for `Combine.Published` — same `wrappedValue`
  /// get/set contract, plus the "enclosing self" subscript Swift's property
  /// wrappers use to reach the instance that owns them (the same mechanism
  /// Combine's own `@Published` relies on to call `objectWillChange.send()`
  /// before a mutation, without every property needing to spell that out by
  /// hand).
  @propertyWrapper
  public struct Published<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
      self.wrappedValue = wrappedValue
    }

    public static subscript<EnclosingSelf: ObservableObject>(
      _enclosingInstance instance: EnclosingSelf,
      wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
      storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Self>
    ) -> Value {
      get { instance[keyPath: storageKeyPath].wrappedValue }
      set {
        if let publisher = instance.objectWillChange as? ObservableObjectPublisher {
          publisher.send()
        }
        instance[keyPath: storageKeyPath].wrappedValue = newValue
      }
    }

    /// Not used anywhere in this codebase today (no call site spells
    /// `$property`) — provided only so a type using this wrapper doesn't
    /// silently lose the `$`-projection syntax `Combine.Published` offers,
    /// should a future Linux caller need it.
    public var projectedValue: Published<Value> { self }
  }

#endif
