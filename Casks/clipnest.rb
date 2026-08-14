cask "clipnest" do
  # `version` and `sha256` below are rewritten automatically by the Release
  # workflow (.github/workflows/release.yml) on every tagged release — no manual
  # edits needed. `:no_check` is only the pre-first-release placeholder.
  version "0.6.0"
  sha256 "95c711b914bccedc9520b15ae740f3eff8b281ade945c656b15783db6b43d67e"

  url "https://github.com/AayushGour/clipnest/releases/download/v#{version}/Clipnest-#{version}.dmg",
      verified: "github.com/AayushGour/clipnest/"
  name "Clipnest"
  desc "Fast, private, native clipboard manager"
  homepage "https://github.com/AayushGour/clipnest"

  # Clipnest is a menu-bar app; no auto-update yet, so no `livecheck`/`auto_updates`.
  # Bare `:sonoma` means "Sonoma or newer" — the `">= :sonoma"` string form is
  # deprecated by Homebrew.
  depends_on macos: :sonoma

  app "Clipnest.app"

  uninstall quit: "com.clipnest.app"

  # `brew uninstall --cask clipnest` removes the app; `--zap` also removes the
  # local history, snippets, and preferences below.
  zap trash: [
    "~/Library/Application Support/Clipnest",
    "~/Library/Caches/com.clipnest.app",
    "~/Library/HTTPStorages/com.clipnest.app",
    "~/Library/Preferences/com.clipnest.app.plist",
  ]

  # Clipnest isn't signed with an Apple Developer ID yet, so macOS Gatekeeper
  # quarantines it on install and blocks first launch. Tell the user how to
  # allow it (there is no `brew trust` command — this is the real step).
  caveats <<~EOS
    Clipnest is not yet notarized, so macOS Gatekeeper will block a Homebrew or
    browser download on first launch ("Apple could not verify … is free of
    malware"). Clear the quarantine attribute once:

      xattr -dr com.apple.quarantine /Applications/Clipnest.app

    Or install/update with the curl script instead, which avoids the quarantine
    flag entirely:

      curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
  EOS
end
