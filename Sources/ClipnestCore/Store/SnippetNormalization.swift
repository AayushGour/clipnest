import Foundation

/// The single derivation rule for a `Snippet`'s search-normalized text —
/// `title` and `body`, space-joined, lowercased.
///
/// Platform-neutral: pure `Foundation`, no `SwiftData` dependency. Extracted
/// out of `SwiftDataSnippetStore.swift` (where `(title + " " + body)
/// .lowercased()` used to be inlined at three separate call sites) so the
/// Linux port's future SQLite-backed `SnippetStore` can reuse this exact
/// derivation instead of reimplementing it and risking drift between the two
/// backing stores — coding-standards.md's DRY rule. Mirrors
/// `ClipItemNormalization`'s identical shape/rationale for `ClipItem`.
///
/// `SnippetRecord.computeNormalizedText(title:body:)` is a one-line
/// forwarder to this function; every call site that used to inline
/// `.lowercased()` directly (`SnippetRecord.init`, `SwiftDataSnippetStore
/// .update(_:title:body:keyword:)`, and `SwiftDataSnippetStore
/// .backfillNormalizedText(in:)`) now calls that forwarder instead — same
/// inputs, same outputs.
public enum SnippetNormalization {
  public static func computeNormalizedText(title: String, body: String) -> String {
    (title + " " + body).lowercased()
  }
}
