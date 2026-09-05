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
// Scope, deliberately minimal: nothing in this codebase actually subscribes
// to `objectWillChange` today (confirmed by grep — no `.sink`/`.receive`/
// `AnyCancellable` anywhere outside this doc comment's own explanation), so
// `ObservableObjectPublisher.send()` only needs to preserve `@Published`'s
// get/set semantics correctly; it does not need a working pub/sub
// implementation to keep every existing behavior identical. A future Linux
// UI layer that needs real change notifications can extend `send()` without
// touching `PickerViewModel.swift` itself.
#if !canImport(Combine)

  /// Portable stand-in for `Combine.ObservableObjectPublisher` — see this
  /// file's top doc comment. `send()` is a no-op today (nothing in this
  /// codebase subscribes to `objectWillChange` — verified by grep before
  /// writing this file); it exists so `@Published`'s enclosing-instance
  /// subscript (below) has something to call before every mutation, matching
  /// Combine's own eager "fire before the value changes" contract, ready for
  /// a future subscriber without any call-site changes.
  public final class ObservableObjectPublisher: Sendable {
    public init() {}

    public func send() {}
  }

  /// Portable stand-in for `Combine.ObservableObject`. Every conforming type
  /// in this codebase relies on the default `objectWillChange` below (none
  /// declares its own), matching how `PickerViewModel.swift` already uses
  /// the real `Combine.ObservableObject`.
  public protocol ObservableObject: AnyObject {
    associatedtype ObjectWillChangePublisher: Sendable = ObservableObjectPublisher
    var objectWillChange: ObjectWillChangePublisher { get }
  }

  extension ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    /// A fresh publisher per access rather than one cached per instance —
    /// sound *only* because nothing in this codebase ever holds onto this
    /// value to subscribe against it (see this file's top doc comment); a
    /// real subscriber would need this to return the SAME instance across
    /// accesses, which `Combine`'s real default achieves via the Objective-C
    /// runtime's associated-object storage — unavailable on Linux. Revisit
    /// this the moment any type conforming to this protocol needs a genuine
    /// subscriber.
    public var objectWillChange: ObservableObjectPublisher {
      ObservableObjectPublisher()
    }
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
