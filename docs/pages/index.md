---
layout: home
title: "Clipnest — Free, Open-Source Clipboard Manager for Mac"
description: "Clipnest is a free, open-source, native macOS clipboard manager: full history, instant search, pins, and snippets that expand by keyword in any app — plus permissions that survive updates."
permalink: /
---

## Why Clipnest?

macOS 26 Tahoe added a basic clipboard history to Spotlight (⌘4) — but it's opt-in, caps out at 7 days, and can't organize, pin, or expand anything. Clipnest is a free, open-source, native menu-bar app that picks up where that leaves off: history you control, instant search, pinned favorites, and reusable snippets that expand by keyword in any app.

### The permission that doesn't disappear on update

Update Clipnest and you don't have to re-grant Accessibility. Every release is signed with the same certificate, so the designated code identity macOS ties your permission grant to stays the same across versions — you're not sent back to System Settings after every update the way you are with apps that rebuild or re-sign between releases. Read the full, honest signing story on the [FAQ]({{ "/faq/" | relative_url }}).

### Free, open source, built in pure SwiftUI

No Electron, no web view. Clipnest is a small, native Swift/SwiftUI app released under the [MIT license](https://github.com/AayushGour/clipnest/blob/main/LICENSE), with the full source on [GitHub](https://github.com/AayushGour/clipnest). No account, no cloud, no telemetry. See exactly what stays on your Mac on the [Privacy page]({{ "/privacy/" | relative_url }}).

### Snippets that expand anywhere you type

Save a signature, a boilerplate reply, or a command as a **snippet**, give it a short **Tag**, then type that Tag in *any* app and press a hotkey — Clipnest replaces it with the snippet's full body. It works the same way in native Cocoa apps and in Electron/Chrome-based ones like VS Code or Slack. If you're running a separate text expander alongside your clipboard manager today, this replaces it too. More on the [Features page]({{ "/features/" | relative_url }}).

![Clipnest's clipboard history picker, showing search and the Snippets tab]({{ "/assets/screenshot-picker.png" | relative_url }})

## What's in the box

- **Full clipboard history** — text, rich text, links, images, and files, captured automatically as you copy.
- **Instant search** — filter your whole history as you type, with matches highlighted.
- **Pinned favorites** — keep what you reuse most a keystroke away, in a dedicated Pinned tab.
- **Snippets with keyword expansion** — see above.
- **Optional on-device OCR** — recognize the text in copied screenshots with Apple's Vision framework, off by default. See the trade-off on the [Privacy page]({{ "/privacy/" | relative_url }}) before turning it on.

## Get it

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
```

Requires macOS 14 (Sonoma) or later. Full install steps, requirements, and the honest signing story are on the [Download page]({{ "/download/" | relative_url }}).

## Learn more

- [Features]({{ "/features/" | relative_url }}) — everything Clipnest does, in detail.
- [Compare]({{ "/compare/" | relative_url }}) — how Clipnest stacks up against Maccy, Deck, and macOS Tahoe's built-in clipboard history.
- [FAQ]({{ "/faq/" | relative_url }}) — pricing, privacy, permissions, and more.
- [Privacy]({{ "/privacy/" | relative_url }}) — exactly what stays on your Mac.
