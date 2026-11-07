// ItemEditorWindow+RichText.swift
//
// T-EDIT9: the `GtkTextBuffer` <-> `[StyledRun]` bridge for the item editor.
// All pure decisions (tag names, run <-> span mapping) live in
// `ItemEditorTagNames` / `StyledRunMapping`; this file only moves them in and
// out of GTK. Offsets are Unicode scalars, which is exactly what
// `GtkTextBuffer` iterators count (characters, not bytes).
import CGtk4
import ClipnestCore

extension ItemEditorWindow {
  /// Replaces the buffer with `initial`. Plain mode (recognized text) sets
  /// the text only and never creates a tag.
  func load(_ initial: EditableRichText, richText: Bool) {
    let (text, spans) = StyledRunMapping.flatten(initial.runs)
    // Not undoable: Ctrl+Z right after opening must not blank the editor.
    gtk_text_buffer_begin_irreversible_action(bufferPointer)
    defer { gtk_text_buffer_end_irreversible_action(bufferPointer) }
    gtk_text_buffer_set_text(buffer, text, Int32(text.utf8.count))
    guard richText else { return }
    for span in spans {
      for name in ItemEditorTagNames.name(for: span.run) {
        guard let tag = ensureTag(name) else { continue }
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(bufferPointer, &start, Int32(span.start))
        gtk_text_buffer_get_iter_at_offset(bufferPointer, &end, Int32(span.start + span.length))
        gtk_text_buffer_apply_tag(bufferPointer, tagPointer(tag), &start, &end)
      }
    }
  }

  func currentText() -> String {
    var start = GtkTextIter()
    var end = GtkTextIter()
    gtk_text_buffer_get_start_iter(buffer, &start)
    gtk_text_buffer_get_end_iter(buffer, &end)
    guard let cString = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
    defer { g_free(cString) }
    return String(cString: cString)
  }

  /// The buffer's content as styled runs: walks tag toggles, so each segment
  /// has one constant tag set.
  func currentRuns() -> [StyledRun] {
    let text = currentText()
    var spans: [StyleSpan] = []
    var cursor = GtkTextIter()
    var end = GtkTextIter()
    gtk_text_buffer_get_start_iter(buffer, &cursor)
    gtk_text_buffer_get_end_iter(buffer, &end)
    while gtk_text_iter_is_end(&cursor) == 0 {
      let segmentStart = cursor
      let advanced = gtk_text_iter_forward_to_tag_toggle(&cursor, nil) != 0
      if !advanced { cursor = end }
      var probe = segmentStart
      let names = tags.compactMap { entry -> String? in
        gtk_text_iter_has_tag(&probe, tagPointer(entry.value)) != 0 ? entry.key : nil
      }
      let length = Int(gtk_text_iter_get_offset(&cursor) - gtk_text_iter_get_offset(&probe))
      if !names.isEmpty, length > 0 {
        spans.append(
          StyleSpan(
            start: Int(gtk_text_iter_get_offset(&probe)), length: length,
            run: ItemEditorTagNames.style(fromTagNames: names)))
      }
    }
    return StyledRunMapping.runs(text: text, spans: spans)
  }

  /// Toggles `name` on the current selection: removed if the whole selection
  /// already has it, applied otherwise. No selection: no-op (documented
  /// limitation, see this type's top doc comment).
  func toggleStyle(tagNamed name: String) {
    guard !isRecognizedText, let tag = ensureTag(name) else { return }
    var start = GtkTextIter()
    var end = GtkTextIter()
    guard gtk_text_buffer_get_selection_bounds(bufferPointer, &start, &end) != 0 else { return }
    if selectionFullyHasTag(tag, from: start, to: end) {
      gtk_text_buffer_remove_tag(bufferPointer, tagPointer(tag), &start, &end)
    } else {
      gtk_text_buffer_apply_tag(bufferPointer, tagPointer(tag), &start, &end)
    }
    syncStyleButtons()
  }

  /// Ctrl+Tab: a literal tab at the cursor (replacing any selection).
  func insertTab() {
    gtkInsertLiteralTab(into: buffer)
  }

  /// Makes each toggle button's pressed state match the selection: on only
  /// when the whole selection has that style (no selection: all off, since
  /// the editor keeps no typing style). Orca reads this as "pressed".
  func syncStyleButtons() {
    var start = GtkTextIter()
    var end = GtkTextIter()
    let hasSelection = gtk_text_buffer_get_selection_bounds(bufferPointer, &start, &end) != 0
    for (name, button) in styleButtons {
      var active = false
      if hasSelection, let tag = tags[name] {
        active = selectionFullyHasTag(tag, from: start, to: end)
      }
      let desired: Int32 = active ? 1 : 0
      if gtk_toggle_button_get_active(button) != desired {
        gtk_toggle_button_set_active(button, desired)
      }
    }
  }

  private func selectionFullyHasTag(
    _ tag: OpaquePointer, from start: GtkTextIter, to end: GtkTextIter
  ) -> Bool {
    var cursor = start
    guard gtk_text_iter_has_tag(&cursor, tagPointer(tag)) != 0 else { return false }
    var limit = end
    // A toggle strictly before the selection end means the tag stops inside it.
    if gtk_text_iter_forward_to_tag_toggle(&cursor, tagPointer(tag)) != 0 {
      return gtk_text_iter_compare(&cursor, &limit) >= 0
    }
    return true
  }

  private func ensureTag(_ name: String) -> OpaquePointer? {
    if let existing = tags[name] { return existing }
    guard let tag = GTKTextStyling.tag(named: name, in: buffer) else { return nil }
    tags[name] = tag
    return tag
  }

  private var bufferPointer: UnsafeMutablePointer<GtkTextBuffer> { gtkPointer(buffer) }

  private func tagPointer(_ tag: OpaquePointer) -> UnsafeMutablePointer<GtkTextTag> {
    gtkPointer(tag)
  }
}
