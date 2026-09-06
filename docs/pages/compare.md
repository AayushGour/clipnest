---
layout: page
title: "Clipnest vs Maccy, Deck & macOS Tahoe — Comparison"
description: "How Clipnest compares to Maccy, Deck, and macOS Tahoe's built-in clipboard history: features, price, privacy, and what's actually different."
permalink: /compare/
---

Clipnest is young — **v0.9.0, about a month old, 0 GitHub stars as of this writing** — and it isn't notarized: it's signed with a stable, self-signed certificate rather than a paid Apple Developer ID, so a browser download will show macOS's "unidentified developer" warning (the supported [curl install]({{ "/download/" | relative_url }}) avoids that dialog and verifies a checksum instead). We'd rather say that plainly here than have you find out later. See the [FAQ]({{ "/faq/" | relative_url }}) for the full explanation.

Given that, here's an honest look at how Clipnest compares to the built-in option in macOS 26 Tahoe and to two other real clipboard managers people ask about — **Maccy**, a well-established free and open-source project, and **Deck**, a newer but already feature-dense native competitor. Every claim below was checked directly against each project's own site, repo, or Apple's own documentation — not copied from an internal roadmap doc. Sources and fetch dates are listed at the bottom.

## vs. macOS 26 Tahoe's built-in clipboard history

macOS 26 Tahoe added a clipboard history to Spotlight — press **⌘Space** then **⌘4** (or click to the right of the search field) to open it. It's **opt-in**: the first time you search your Clipboard, Spotlight asks you to click Enable. From there you can search past copies, click an item to make it the current clipboard, or clear the whole history. By default it keeps items for **8 hours**; as of macOS 26.1 you can shorten that to 30 minutes for more privacy or extend it up to **7 days**.

That's genuinely useful, and it's free, built in, and requires nothing extra. But it stops there — there's no pinning, no custom organization, no way to save a snippet, and no keyword expansion. If Spotlight's clipboard history already covers how you use copy-paste, you may not need a third-party app at all. Clipnest is for when you want history that doesn't quietly age out, favorites you can pin, and reusable text you can expand by keyword in any app — none of which Tahoe's version does.

One more real difference: Tahoe's clipboard history requires **macOS 26**. Clipnest (and Maccy, and Deck) all run on **macOS 14 (Sonoma) and later**, so they're the only option if you're not on the newest macOS yet.

## vs. Maccy

[Maccy](https://github.com/p0deje/Maccy) is the free, open-source clipboard manager most people mean when they say "just use a simple one." It's been around since 2018, it's MIT-licensed, and it has **~21,500 GitHub stars** — a track record Clipnest, at one month old, simply doesn't have yet. If you want the most established free option with the biggest community behind it, Maccy is a legitimately good choice, and we say that without qualification.

Maccy does clipboard history, fast keyboard-first search, and — something worth correcting if you've heard otherwise — it does have pinning: press **⌥P** on a history item to keep it at the top with its own shortcut. What it doesn't do is snippets with keyword expansion, on-device OCR, type filters, or a full Settings UI (its preferences are a single panel, with several options set via `defaults write` in Terminal rather than a GUI). Clipnest covers everything Maccy does for plain clipboard history and search, then adds a dedicated Pinned tab, snippets that expand by keyword in any app, optional OCR, and a five-tab Settings window — at the cost of being a brand-new project without Maccy's years of real-world hardening.

## vs. Deck

[Deck](https://github.com/yuzeguitarist/Deck) is the closest architectural twin to Clipnest — a native Swift/SwiftUI menu-bar clipboard manager, not Electron — and it's more feature-dense than either Clipnest or Maccy: keyword/regex/on-device semantic search, background OCR, a rule-based automation system with JavaScript plugins, Touch ID lock, encrypted LAN sharing between Macs, a queue/multi-paste mode, and a "Cursor Assistant" that offers trigger-word-based text snippets from a template library (a different mechanism from Clipnest's type-a-tag-then-hotkey expansion, but a similar idea). It's also free — Deck states plainly on its own pricing page that every feature is included at $0, no tiers. And it already has real traction: **~1,400 GitHub stars** in about nine months, more than Clipnest has in its first month.

The place Deck is a meaningfully different proposition is licensing: its own `LICENSE` file splits the repo in two — one subdirectory under AGPL-3.0, and *everything else* (most of the actual app) marked source-available and "All Rights Reserved," with reuse, modification, and redistribution of that part requiring the author's written permission. That's not the same as Clipnest's plain MIT license, which allows unrestricted use, modification, and redistribution of the entire codebase. Deck's own README also states it isn't notarized via Apple's paid Developer Program, the same honest position Clipnest is in.

If you want the single most feature-packed free clipboard manager and the license terms don't matter to you, Deck is genuinely worth a look. If an OSI-approved open-source license matters — for auditing, forking, or just principle — that's where Clipnest and Maccy differ from Deck.

## Side by side

| | Clipnest | Maccy | Deck | macOS 26 Tahoe (Spotlight) |
|---|---|---|---|---|
| Price | Free | Free | Free | Free (built in) |
| License | MIT (open source) | MIT (open source) | Source-available — AGPL-3.0 for one subdirectory, all-rights-reserved for the rest | N/A — a system feature |
| Minimum macOS | 14 (Sonoma) | 14 (Sonoma) | 14 (Sonoma) | 26 (Tahoe) only |
| Maturity (as of Sept 2026) | v0.9.0, ~1 month old, 0 GitHub stars | Since 2018, ~21,500 GitHub stars | ~9 months old, ~1,400 GitHub stars | New in macOS 26; retention options added in 26.1 |
| History retention | 1,000 items by default; switch to a day-based cap or unlimited | No expiry documented | Unlimited, per its own pricing page | 8 hours by default; 30 min–7 days, configurable (26.1+) |
| Pinning | Dedicated Pinned tab | Yes, via ⌥P (moves item to top, assigns a shortcut) | Not a named feature — has tags and smart categories instead | None |
| Search | Instant, real-time, highlighted matches | Real-time search | Keyword, regex, and on-device semantic search | Basic text search inside Spotlight |
| Snippets / text expansion | Yes — type a Tag anywhere, expand by hotkey | No | Template Library + trigger-word "Cursor Assistant" (different mechanism) | No |
| On-device OCR | Optional, off by default | No | Yes, runs automatically in the background | No |
| Notarized | No — self-signed certificate, stable across releases | Not covered in this comparison (not independently confirmed) | No, per its own README | N/A |

No aggregate score here on purpose — these are genuinely different trade-offs, not a strict better/worse ranking. Maccy is the safest, most proven free choice. Deck packs in the most features if a source-available license is fine with you. Tahoe's built-in history is enough if all you need is basic recall. Clipnest's bet is snippets-plus-clipboard in one small, real-MIT, native app, with the honesty of being brand new laid out above rather than hidden.

## Sources (fetched September 6, 2026)

- Maccy: [p0deje/Maccy on GitHub](https://github.com/p0deje/Maccy) — star count, license, and feature list via the GitHub API and the repo's own README.
- Deck: [yuzeguitarist/Deck on GitHub](https://github.com/yuzeguitarist/Deck), its [LICENSE file](https://github.com/yuzeguitarist/Deck/blob/main/LICENSE), and [deckclip.app/pricing](https://deckclip.app/pricing) — star count, license terms, features, and pricing.
- macOS 26 Tahoe clipboard history: [Apple Support — "Search your Clipboard history in Spotlight on Mac"](https://support.apple.com/en-in/guide/mac-help/mchl40d5b86b/mac) (opt-in behavior, search/copy/clear); [Cult of Mac, published Feb 14, 2026](https://www.cultofmac.com/how-to/mac-clipboard-history) (retention window: 8 hours default, 30 min–7 days configurable since macOS 26.1); [MacMost, published Sept 22, 2025](https://macmost.com/how-to-use-the-spotlight-clipboard-history-in-macos-tahoe.html) (no pinning or custom organization).
- Clipnest: this repository's own [README](https://github.com/AayushGour/clipnest/blob/main/README.md), [LICENSE](https://github.com/AayushGour/clipnest/blob/main/LICENSE), and [releases](https://github.com/AayushGour/clipnest/releases).
