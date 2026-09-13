#if os(macOS)
  import Foundation
  import Testing

  @testable import ClipnestCore

  @Suite("MacTerminalAppRegistry")
  struct MacTerminalAppRegistryTests {
    @Test("every registered terminal bundle identifier is recognized")
    func knownTerminalsAreRecognized() {
      for identifier in MacTerminalAppRegistry.terminalBundleIdentifiers {
        #expect(
          MacTerminalAppRegistry.isTerminal(bundleIdentifier: identifier),
          "expected \(identifier) to be recognized as a terminal")
      }
    }

    @Test("an ordinary app is never mistaken for a terminal")
    func ordinaryAppIsNotATerminal() {
      #expect(!MacTerminalAppRegistry.isTerminal(bundleIdentifier: "com.apple.TextEdit"))
      #expect(!MacTerminalAppRegistry.isTerminal(bundleIdentifier: "com.apple.Safari"))
    }

    @Test("a nil bundle identifier is never assumed to be a terminal")
    func nilIdentifierIsNotATerminal() {
      #expect(!MacTerminalAppRegistry.isTerminal(bundleIdentifier: nil))
    }

    @Test("the registry contains exactly the terminals verified against primary sources")
    func containsVerifiedTerminals() {
      let expected: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
      ]
      #expect(MacTerminalAppRegistry.terminalBundleIdentifiers == expected)
    }
  }
#endif
