import ClipnestCore
import Foundation

/// The lowest-priority backend: reports it cannot synthesize a keystroke,
/// so `Paster` propagates `PasteError.eventPostFailed` while the content it
/// already wrote to the pasteboard (before this is ever reached — see
/// `Paster.paste`) remains available. The app degrades to "content is on
/// the clipboard, press Ctrl+V" — selected when neither uinput nor XTEST is
/// usable (see `LinuxEventSynthesizerSelection`).
public struct NullClipboardOnlyEventSynthesizer: EventSynthesizing {
  public init() {}

  public func synthesizeCommandV(targeting app: FrontmostAppRef) throws {
    throw PasteError.eventPostFailed
  }
}
