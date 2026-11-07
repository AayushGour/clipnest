import Foundation

/// Single-pass, hand-written HTML tokenizer producing `StyledRun`s.
///
/// Built for UNTRUSTED input (clipboard HTML), so it is total and bounded:
/// every loop iteration advances `position`; every scan for a terminator runs
/// at most once per byte (an unterminated construct ends the parse instead of
/// being re-scanned); the open-element stack is capped at
/// `HTMLStyledRunCodec.maxNestingDepth`; attribute values are capped; there is
/// no recursion. Memory is O(input).
struct HTMLStyledRunParser {
  private struct Frame {
    let name: String
    let savedStyle: StyledRun
    let savedPreserve: Bool
    let suppressesText: Bool
  }

  private enum Tag {
    static let transparent: Set<String> = [
      "html", "head", "body", "meta", "title", "style", "script",
    ]
    static let rawText: Set<String> = ["title", "style", "script"]
    static let bold: Set<String> = ["b", "strong"]
    static let italic: Set<String> = ["i", "em"]
    static let underline = "u"
    static let styled: Set<String> = bold.union(italic).union([underline])
    static let plainContainers: Set<String> = ["span", "font", "p", "div"]
    static let blocks: Set<String> = [
      "p", "div", "tr", "li", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6", "pre",
      "blockquote", "hr",
    ]
    static let voids: Set<String> = [
      "br", "meta", "img", "hr", "input", "link", "base", "col", "area", "embed", "param",
      "source", "track", "wbr",
    ]
    static let lineBreak = "br"
    static let head = "head"
    static let body = "body"
    static let paragraph = "p"
    static let font = "font"
    static let maxNameLength = 32
    static let unknownName = "?"
  }

  private enum Attribute {
    static let style = "style"
    static let color = "color"
    static let face = "face"
    static let maxValueBytes = 4_096
  }

  private enum Byte {
    static let lt = UInt8(ascii: "<")
    static let gt = UInt8(ascii: ">")
    static let slash = UInt8(ascii: "/")
    static let bang = UInt8(ascii: "!")
    static let question = UInt8(ascii: "?")
    static let amp = UInt8(ascii: "&")
    static let equals = UInt8(ascii: "=")
    static let dash = UInt8(ascii: "-")
    static let space = UInt8(ascii: " ")
    static let lf = UInt8(ascii: "\n")
    static let cr = UInt8(ascii: "\r")
    static let tab = UInt8(ascii: "\t")
    static let formFeed: UInt8 = 0x0C
    static let doubleQuote = UInt8(ascii: "\"")
    static let singleQuote = UInt8(ascii: "'")
  }

  private let bytes: [UInt8]
  private var position = 0
  private var runs: [StyledRun] = []
  private var buffer: [UInt8] = []
  private var state = HTMLStyleParsing.State(style: StyledRun(text: ""), preserveWhitespace: false)
  private var frames: [Frame] = []
  private var openCounts: [String: Int] = [:]
  private var suppressDepth = 0
  private var breakPending = false
  /// Last emitted byte; starts as a line break so leading whitespace and
  /// leading block breaks are dropped.
  private var lastByte = Byte.lf
  private var hasUnsupported = false
  private var exceededDepth = false

  init(html: String) {
    bytes = Array(html.utf8)
  }

  /// Parses the whole input. Caller has already enforced the size limit.
  static func parse(html: String) -> ParsedStyledText {
    var parser = HTMLStyledRunParser(html: html)
    return parser.run()
  }

  private mutating func run() -> ParsedStyledText {
    while position < bytes.count, !exceededDepth {
      switch bytes[position] {
      case Byte.lt:
        if !consumeMarkup() {
          emit(Byte.lt)
          position += 1
        }
      case Byte.amp:
        consumeEntity()
      default:
        consumeTextByte()
      }
    }
    if exceededDepth { return ParsedStyledText(runs: [], hasUnsupportedContent: true) }
    flush()
    // An unclosed <head> swallowed everything after it.
    if suppressDepth > 0 { hasUnsupported = true }
    return ParsedStyledText(runs: runs, hasUnsupportedContent: hasUnsupported)
  }

  // MARK: - Text

  private mutating func consumeTextByte() {
    let byte = bytes[position]
    position += 1
    switch byte {
    case Byte.space, Byte.tab, Byte.lf, Byte.cr, Byte.formFeed:
      consumeWhitespace(byte)
    case 0..<0x20, 0x7F:
      hasUnsupported = true  // NUL / control characters are dropped
    default:
      emit(byte)
    }
  }

  private mutating func consumeWhitespace(_ byte: UInt8) {
    guard suppressDepth == 0 else { return }
    if state.preserveWhitespace {
      if byte == Byte.cr {
        if position < bytes.count, bytes[position] == Byte.lf { return }
        emit(Byte.lf)
      } else if byte == Byte.formFeed {
        emit(Byte.space)
      } else {
        emit(byte)
      }
    } else if !breakPending, lastByte != Byte.space, lastByte != Byte.lf {
      emit(Byte.space)
    }
  }

  private mutating func consumeEntity() {
    switch HTMLStyleParsing.entity(in: bytes, at: position) {
    case .scalar(let value, let consumed):
      emitScalar(value)
      position += consumed
    case .invalid(let consumed):
      hasUnsupported = true
      emitScalar(HTMLStyleParsing.replacementScalar)
      position += consumed
    case .unknownNamed:
      hasUnsupported = true
      emit(Byte.amp)
      position += 1
    case .none:
      emit(Byte.amp)
      position += 1
    }
  }

  private mutating func emitScalar(_ value: UInt32) {
    guard suppressDepth == 0 else { return }
    let scalar = Unicode.Scalar(value) ?? "\u{FFFD}"
    beginContent()
    buffer.append(contentsOf: Array(String(scalar).utf8))
    lastByte = buffer[buffer.count - 1]
  }

  private mutating func emit(_ byte: UInt8) {
    guard suppressDepth == 0 else { return }
    beginContent()
    buffer.append(byte)
    lastByte = byte
  }

  /// Inserts the pending block-boundary newline before real content.
  private mutating func beginContent() {
    guard breakPending else { return }
    breakPending = false
    if lastByte != Byte.lf {
      buffer.append(Byte.lf)
      lastByte = Byte.lf
    }
  }

  private mutating func flush() {
    guard !buffer.isEmpty else { return }
    var run = state.style
    run.text = String(decoding: buffer, as: UTF8.self)
    buffer.removeAll(keepingCapacity: true)
    if let last = runs.last, last.hasSameStyle(as: run) {
      runs[runs.count - 1].text += run.text
    } else {
      runs.append(run)
    }
  }

  // MARK: - Markup

  /// Handles `<…` at `position`. Returns false when the `<` is plain text.
  private mutating func consumeMarkup() -> Bool {
    guard position + 1 < bytes.count else { return false }
    let next = bytes[position + 1]
    if next == Byte.bang {
      skipDeclarationOrComment()
      return true
    }
    if next == Byte.question {
      skip(past: Byte.gt, from: position + 2)
      return true
    }
    if next == Byte.slash {
      guard position + 2 < bytes.count, isLetter(bytes[position + 2]) else { return false }
      position += 2
      let name = readName()
      skip(past: Byte.gt, from: position)
      closeElement(name)
      return true
    }
    guard isLetter(next) else { return false }
    position += 1
    openTag()
    return true
  }

  private mutating func skipDeclarationOrComment() {
    let isComment =
      position + 3 < bytes.count && bytes[position + 2] == Byte.dash
      && bytes[position + 3] == Byte.dash
    guard isComment else {
      skip(past: Byte.gt, from: position + 2)
      return
    }
    var index = position + 4
    while index + 2 < bytes.count {
      if bytes[index] == Byte.dash, bytes[index + 1] == Byte.dash, bytes[index + 2] == Byte.gt {
        position = index + 3
        return
      }
      index += 1
    }
    position = bytes.count
  }

  /// Moves `position` just past the next `byte` at or after `from`, or to the
  /// end of input when there is none (the rest is an unterminated construct).
  private mutating func skip(past byte: UInt8, from: Int) {
    var index = from
    while index < bytes.count, bytes[index] != byte { index += 1 }
    position = min(index + 1, bytes.count)
  }

  private mutating func readName() -> String {
    let start = position
    while position < bytes.count, isNameByte(bytes[position]) { position += 1 }
    guard position - start <= Tag.maxNameLength else { return Tag.unknownName }
    return String(decoding: bytes[start..<position], as: UTF8.self).lowercased()
  }

  private mutating func openTag() {
    let name = readName()
    var styleAttribute: String?
    var colorAttribute: String?
    var faceAttribute: String?
    var selfClosing = false

    scan: while true {
      while position < bytes.count, isSpace(bytes[position]) { position += 1 }
      guard position < bytes.count else { return }  // unterminated tag: drop it
      let byte = bytes[position]
      if byte == Byte.gt {
        position += 1
        break scan
      }
      if byte == Byte.slash {
        selfClosing = position + 1 < bytes.count && bytes[position + 1] == Byte.gt
        position += 1
        continue
      }
      let nameStart = position
      while position < bytes.count, !isSpace(bytes[position]), bytes[position] != Byte.equals,
        bytes[position] != Byte.gt, bytes[position] != Byte.slash
      {
        position += 1
      }
      if position == nameStart {
        position += 1  // stray '=' or similar: always make progress
        continue
      }
      let attribute = String(
        decoding: bytes[nameStart..<min(position, nameStart + 32)], as: UTF8.self
      )
      .lowercased()
      while position < bytes.count, isSpace(bytes[position]) { position += 1 }
      guard position < bytes.count, bytes[position] == Byte.equals else { continue }
      position += 1
      while position < bytes.count, isSpace(bytes[position]) { position += 1 }
      guard position < bytes.count else { return }
      guard let value = readAttributeValue() else { return }
      guard value.count <= Attribute.maxValueBytes else { continue }
      switch attribute {
      case Attribute.style: styleAttribute = HTMLStyleParsing.decodeAttribute(value)
      case Attribute.color: colorAttribute = HTMLStyleParsing.decodeAttribute(value)
      case Attribute.face: faceAttribute = HTMLStyleParsing.decodeAttribute(value)
      default: break
      }
    }

    openElement(
      name, style: styleAttribute, color: colorAttribute, face: faceAttribute,
      selfClosing: selfClosing)
  }

  /// Reads a quoted or bare attribute value; nil when a quote never closes
  /// (the parse then ends — the scan is not repeated).
  private mutating func readAttributeValue() -> ArraySlice<UInt8>? {
    let first = bytes[position]
    if first == Byte.doubleQuote || first == Byte.singleQuote {
      var index = position + 1
      while index < bytes.count, bytes[index] != first { index += 1 }
      guard index < bytes.count else {
        position = bytes.count
        return nil
      }
      defer { position = index + 1 }
      return bytes[(position + 1)..<index]
    }
    let start = position
    while position < bytes.count, !isSpace(bytes[position]), bytes[position] != Byte.gt {
      position += 1
    }
    return bytes[start..<position]
  }

  // MARK: - Elements

  private mutating func openElement(
    _ name: String, style: String?, color: String?, face: String?, selfClosing: Bool
  ) {
    if Tag.rawText.contains(name) {
      if !selfClosing { skipRawText(of: name) }
      return
    }
    if name == Tag.lineBreak {
      if suppressDepth == 0 {
        beginContent()
        buffer.append(Byte.lf)
        lastByte = Byte.lf
      }
      return
    }
    if Tag.voids.contains(name) || selfClosing && !Tag.transparent.contains(name) {
      if !Tag.transparent.contains(name) { hasUnsupported = true }
      if Tag.blocks.contains(name) { breakPending = true }
      if Tag.voids.contains(name) || selfClosing { return }
    }
    if name == Tag.paragraph, frames.last?.name == Tag.paragraph { closeElement(Tag.paragraph) }
    if name == Tag.body { closeElement(Tag.head) }
    guard frames.count < HTMLStyledRunCodec.maxNestingDepth else {
      exceededDepth = true
      return
    }

    let known =
      Tag.transparent.contains(name) || Tag.styled.contains(name)
      || Tag.plainContainers.contains(name)
    if !known { hasUnsupported = true }

    var next = HTMLStyleParsing.State(
      style: state.style, preserveWhitespace: state.preserveWhitespace)
    if Tag.bold.contains(name) { next.style.bold = true }
    if Tag.italic.contains(name) { next.style.italic = true }
    if name == Tag.underline { next.style.underline = true }
    if name == Tag.font {
      if let color { HTMLStyleParsing.setColor(color, on: &next) }
      if let face { HTMLStyleParsing.setFamily(face, on: &next) }
    }
    if let style { HTMLStyleParsing.applyCSS(style, to: &next) }
    if next.hasUnsupported { hasUnsupported = true }

    if !next.style.hasSameStyle(as: state.style) { flush() }
    let suppresses = name == Tag.head
    frames.append(
      Frame(
        name: name, savedStyle: state.style, savedPreserve: state.preserveWhitespace,
        suppressesText: suppresses))
    openCounts[name, default: 0] += 1
    if suppresses { suppressDepth += 1 }
    state.style = next.style
    state.preserveWhitespace = next.preserveWhitespace
    if Tag.blocks.contains(name) { breakPending = true }
    if selfClosing { closeElement(name) }
  }

  private mutating func closeElement(_ name: String) {
    guard openCounts[name, default: 0] > 0 else { return }
    var restored: Frame?
    while let frame = frames.popLast() {
      openCounts[frame.name, default: 1] -= 1
      if frame.suppressesText { suppressDepth -= 1 }
      if frame.name == name {
        restored = frame
        break
      }
    }
    guard let restored else { return }
    if !restored.savedStyle.hasSameStyle(as: state.style) { flush() }
    state.style = restored.savedStyle
    state.preserveWhitespace = restored.savedPreserve
    if Tag.blocks.contains(name) { breakPending = true }
  }

  /// Skips the content of `script`/`style`/`title` up to its closing tag.
  private mutating func skipRawText(of name: String) {
    let closing = Array("</\(name)".utf8)
    var index = position
    while index + closing.count <= bytes.count {
      var matches = true
      for offset in 0..<closing.count where (bytes[index + offset] | 0x20) != closing[offset] | 0x20
      {
        matches = false
        break
      }
      if matches {
        skip(past: Byte.gt, from: index + closing.count)
        return
      }
      index += 1
    }
    position = bytes.count
  }

  // MARK: - Byte classes

  private func isLetter(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20)
  }

  private func isNameByte(_ byte: UInt8) -> Bool {
    isLetter(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == Byte.dash
      || byte == UInt8(ascii: ":")
  }

  private func isSpace(_ byte: UInt8) -> Bool {
    byte == Byte.space || byte == Byte.tab || byte == Byte.lf || byte == Byte.cr
      || byte == Byte.formFeed
  }
}
