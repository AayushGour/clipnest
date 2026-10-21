// SnippetTagValidationTests.swift
//
// T-SNIPFB1: duplicate-Tag rule, expansion-failure copy, and the view-model
// wiring (inline error + refusal to write a duplicate).

import ClipnestCore
import Foundation
import Testing

@testable import ClipnestViewModels

@Suite("SnippetTagValidation")
struct SnippetTagValidationTests {
  private let sig = Snippet(title: "Signature", body: "Best", keyword: "sig")

  @Test("A tag used by another snippet conflicts, naming that snippet")
  func conflictNamesSnippet() {
    let conflict = SnippetTagValidation.conflict(forTag: "sig", editing: nil, in: [sig])
    #expect(conflict?.id == sig.id)
    #expect(SnippetTagValidation.message(forConflict: sig).contains("Signature"))
  }

  @Test("Case and surrounding whitespace do not make a tag unique (matches findByKeyword)")
  func caseAndWhitespaceFold() async throws {
    #expect(SnippetTagValidation.conflict(forTag: "  SIG ", editing: nil, in: [sig]) != nil)
    // The rule must agree with the real lookup used by expansion.
    let store = InMemorySnippetStore()
    _ = try await store.create(sig)
    for tag in ["sig", "SIG", "  Sig  ", "other", ""] {
      let lookup = try await store.findByKeyword(tag)
      let conflict = SnippetTagValidation.conflict(forTag: tag, editing: nil, in: [sig])
      #expect((lookup != nil) == (conflict != nil), "tag \(tag.debugDescription)")
    }
  }

  @Test("Editing a snippet may keep its own tag")
  func editingOwnTagIsFine() {
    #expect(SnippetTagValidation.conflict(forTag: "sig", editing: sig.id, in: [sig]) == nil)
  }

  @Test("Blank tags and snippets without a keyword never conflict")
  func blanksNeverConflict() {
    let noKeyword = Snippet(title: "x", body: "y", keyword: nil)
    #expect(SnippetTagValidation.conflict(forTag: "  ", editing: nil, in: [sig]) == nil)
    #expect(SnippetTagValidation.conflict(forTag: "x", editing: nil, in: [noKeyword]) == nil)
  }
}

@Suite("SnippetExpansionCopy")
struct SnippetExpansionCopyTests {
  @Test("Each failure gets its own non-empty message, and selection hints name the shortcut")
  func messagesAreDistinct() {
    let cases: [SnippetExpansionFailure] = [
      .noSelection, .noMatch, .permissionMissing, .replaceFailed,
    ]
    let messages = cases.map { SnippetExpansionCopy.message(for: $0, expandShortcut: "⌥⌘E") }
    #expect(Set(messages).count == cases.count)
    #expect(messages.allSatisfy { !$0.isEmpty })
    #expect(messages[0].contains("⌥⌘E"))
  }

  @Test("Helper text names the tag role and the shortcut")
  func helperText() {
    let text = SnippetExpansionCopy.tagHelperText(expandShortcut: "Ctrl+Alt+E")
    #expect(text.contains("Ctrl+Alt+E"))
    #expect(text.contains("tag"))
  }
}

@MainActor
@Suite("PickerViewModel snippet tag uniqueness")
struct PickerViewModelSnippetTagTests {
  @Test("snippetTagError reports a duplicate after the editor opens; create refuses a duplicate")
  func errorAndRefusal() async throws {
    let (_, blobStore) = makeTempBlobStore()
    let snippetStore = InMemorySnippetStore()
    _ = try await snippetStore.create(Snippet(title: "Signature", body: "Best", keyword: "sig"))
    let viewModel = makeTestPickerViewModel(
      clipStore: InMemoryClipStore(blobStore: blobStore), snippetStore: snippetStore,
      blobStore: blobStore, showPreviewOnKeyboardSelection: { false })
    viewModel.presentSnippetEditor = { _ in }

    viewModel.presentCreateSnippetForm()
    await waitUntil { viewModel.snippetTagError(forTag: "SIG", editing: nil) != nil }
    #expect(viewModel.snippetTagError(forTag: "SIG", editing: nil)?.contains("Signature") == true)
    #expect(viewModel.snippetTagError(forTag: "fresh", editing: nil) == nil)

    viewModel.createSnippet(title: "Dup", body: "x", keyword: "Sig")
    try await Task.sleep(for: .milliseconds(150))
    #expect(try await snippetStore.fetchAll().count == 1)

    viewModel.createSnippet(title: "Fresh", body: "x", keyword: "fresh")
    try await Task.sleep(for: .milliseconds(200))
    #expect(try await snippetStore.fetchAll().count == 2)
  }
}
