cask "clipnest" do
  # `version` and `sha256` below are rewritten automatically by the Release
  # workflow (.github/workflows/release.yml) on every tagged release — no manual
  # edits needed. `:no_check` is only the pre-first-release placeholder.
  version "0.3.0"
  sha256 :no_check

  url "https://github.com/AayushGour/clipnest/releases/download/v#{version}/Clipnest-#{version}.dmg",
      verified: "github.com/AayushGour/clipnest/"
  name "Clipnest"
  desc "Fast, private, native clipboard manager for macOS"
  homepage "https://github.com/AayushGour/clipnest"

  # Clipnest is a menu-bar app; no auto-update yet, so no `livecheck`/`auto_updates`.
  depends_on macos: ">= :sonoma"

  app "Clipnest.app"

  uninstall quit: "com.clipnest.app"

  # `brew uninstall --cask clipnest` removes the app; `--zap` also removes the
  # local history, snippets, and preferences below.
  zap trash: [
    "~/Library/Application Support/Clipnest",
    "~/Library/Preferences/com.clipnest.app.plist",
    "~/Library/Caches/com.clipnest.app",
    "~/Library/HTTPStorages/com.clipnest.app",
  ]
end
