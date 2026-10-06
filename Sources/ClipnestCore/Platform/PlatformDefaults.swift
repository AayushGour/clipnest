import Foundation

/// The single place where platform-specific default collaborators are resolved.
///
/// Types in `ClipnestCore` take their collaborators as injected parameters, but
/// their *default arguments* used to name AppKit types directly (e.g.
/// `= WorkspaceFrontmostAppReferenceProvider()`), which is what actually blocks a
/// Linux build — a `#if` inside a parameter list is both unreadable and a
/// `swift-format --strict` hazard. Instead each such default resolves through a
/// static member here, and the platform-specific value is supplied by an
/// `extension PlatformDefaults` in the file that owns that platform's
/// implementation:
///
/// - macOS values live beside their implementations under `Platform/macOS/`.
/// - Non-Apple values are portable no-ops, documented as "never used in
///   production" — the Linux composition root always injects a real backend.
///
/// Keeping one initializer signature per type (rather than per-platform
/// overloads) is what lets the existing macOS test suite compile untouched.
public enum PlatformDefaults {}
