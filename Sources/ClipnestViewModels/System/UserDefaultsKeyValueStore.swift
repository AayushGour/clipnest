// UserDefaultsKeyValueStore.swift
//
// `UserDefaults` already satisfies `KeyValueStore`'s every requirement by
// construction (see that protocol's doc comment) — this file only supplies
// the conformance declaration itself, plus the `Sendable` conformance
// `KeyValueStore` requires.
//
// Deliberately portable (not `#if os(macOS)`-gated): `UserDefaults` compiles
// and works on Linux too (verified empirically — see `KeyValueStore.swift`'s
// doc comment), and `SettingsStoreTests`'s 13 cases construct `UserDefaults`
// directly and must keep compiling, unedited, on both platforms (P5's "the
// only permitted edit to a moved test is its import line" rule). What IS
// macOS-only is `SettingsStore`'s own `UserDefaults`-typed convenience
// initializer and `PlatformDefaults.keyValueStore`'s *production default* —
// see `Platform/macOS/PlatformDefaultsKeyValueStore.swift` and
// `SettingsStore.swift`.
import Foundation

// `KeyValueStore` refines `Sendable`, but `UserDefaults` is declared
// `@_nonSendable`/unavailable-Sendable in both Apple's Foundation and
// swift-corelibs-foundation, so the conformance must be spelled out as
// `@retroactive @unchecked` in a standalone extension — mirrors
// `ClipnestCore/Platform/macOS/MacPasteboardWriting.swift`'s identical
// `NSPasteboard: @retroactive @unchecked Sendable` extension and its exact
// justification: `UserDefaults` is a documented thread-safe system type, so
// `@unchecked` is sound here. Verified empirically (both Apple Foundation and
// swift-corelibs-foundation on Linux mark the real conformance
// unavailable/`@_nonSendable`, and both accept this retroactive override).
// swift-format-ignore: AvoidRetroactiveConformances
extension UserDefaults: @retroactive @unchecked Sendable {}

extension UserDefaults: KeyValueStore {}
