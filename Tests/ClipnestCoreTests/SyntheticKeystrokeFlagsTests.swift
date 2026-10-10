// SyntheticKeystrokeFlagsTests.swift
//
// Pins the modifier flags `SyntheticKeystroke.postCommandModified` stamps on
// its synthetic ⌘ chord. Microsoft Word ignored the chord while it carried
// only `.maskCommand`; it needs the left-Command device bit a real key press
// sets too. No event is posted here — only the flag constants are checked.
#if os(macOS)
  import CoreGraphics
  import Testing

  @testable import ClipnestCore

  @Suite("SyntheticKeystroke flags")
  struct SyntheticKeystrokeFlagsTests {
    @Test("Left-Command device bit is NX_DEVICELCMDKEYMASK (0x08)")
    func deviceLeftCommandBitValue() {
      #expect(SyntheticKeystroke.deviceLeftCommandFlag.rawValue == 0x08)
    }

    @Test("Command chord carries both the generic and the left-device Command bits")
    func chordFlagsMatchARealLeftCommandPress() {
      let flags = SyntheticKeystroke.commandChordFlags
      #expect(flags.contains(.maskCommand))
      #expect(flags.contains(SyntheticKeystroke.deviceLeftCommandFlag))
      #expect(flags.rawValue == CGEventFlags.maskCommand.rawValue | 0x08)
    }

    @Test("Command chord asserts no other modifier")
    func chordFlagsAssertNoOtherModifier() {
      let flags = SyntheticKeystroke.commandChordFlags
      #expect(!flags.contains(.maskAlternate))
      #expect(!flags.contains(.maskShift))
      #expect(!flags.contains(.maskControl))
    }
  }
#endif
