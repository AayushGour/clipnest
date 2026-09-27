---
layout: home
title: "Clipnest — Free, Open-Source Clipboard Manager for Mac"
description: "Clipnest is a free, open-source, native macOS clipboard manager: full history, instant search, pins, and snippets that expand by keyword in any app — plus permissions that survive updates."
permalink: /
---

<section class="hero-visual">
<div class="shell" markdown="1">

<div class="shot-frame" markdown="1">

![Clipnest's clipboard history picker, showing search and the Snippets tab]({{ "/assets/screenshot-picker.png" | relative_url }})

</div>

</div>
</section>

<section class="cta-strip">
<div class="shell" markdown="1">

## Get it

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
```

</div>

Requires macOS 14 (Sonoma) or later. Full install steps, requirements, and the honest signing story are on the [Download page]({{ "/download/" | relative_url }}).

</div>
</section>

<section class="section">
<div class="shell">

<div class="section-head" markdown="1">

## Why Clipnest?

macOS 26 Tahoe added a basic clipboard history to Spotlight (⌘4) — but it's opt-in, caps out at 7 days, and can't organize, pin, or expand anything. Clipnest is a free, open-source, native menu-bar app that picks up where that leaves off: history you control, instant search, pinned favorites, and reusable snippets that expand by keyword in any app.

</div>

<div class="feature-grid">

<div class="feature-card" markdown="1">

### The permission that doesn't disappear on update

Update Clipnest and you don't have to re-grant Accessibility. Every release is signed with the same certificate, so the designated code identity macOS ties your permission grant to stays the same across versions — you're not sent back to System Settings after every update the way you are with apps that rebuild or re-sign between releases. Read the full, honest signing story on the [FAQ]({{ "/faq/" | relative_url }}).

</div>

<div class="feature-card" markdown="1">

### Free, open source, built in pure SwiftUI

No Electron, no web view. Clipnest is a small, native Swift/SwiftUI app released under the [MIT license](https://github.com/AayushGour/clipnest/blob/main/LICENSE), with the full source on [GitHub](https://github.com/AayushGour/clipnest). No account, no cloud, no telemetry. See exactly what stays on your Mac on the [Privacy page]({{ "/privacy/" | relative_url }}).

</div>

<div class="feature-card" markdown="1">

### Snippets that expand anywhere you type

Save a signature, a boilerplate reply, or a command as a **snippet**, give it a short **Tag**, then type that Tag in *any* app and press a hotkey — Clipnest replaces it with the snippet's full body. It works the same way in native Cocoa apps and in Electron/Chrome-based ones like VS Code or Slack. If you're running a separate text expander alongside your clipboard manager today, this replaces it too. More on the [Features page]({{ "/features/" | relative_url }}).

</div>

</div>

</div>
</section>

<section class="section box-grid">
<div class="shell" markdown="1">

## What's in the box

<ul>
<li>
<span class="box-grid-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<rect x="4" y="4" width="16" height="16" rx="3"></rect>
<line x1="8" y1="9" x2="16" y2="9"></line>
<line x1="8" y1="13" x2="16" y2="13"></line>
<line x1="8" y1="17" x2="13" y2="17"></line>
</svg>
</span>
<h3>Full clipboard history</h3>
<p>text, rich text, links, images, and files, captured automatically as you copy.</p>
</li>
<li>
<span class="box-grid-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<circle cx="10.5" cy="10.5" r="6.5"></circle>
<line x1="15.3" y1="15.3" x2="20" y2="20"></line>
</svg>
</span>
<h3>Instant search</h3>
<p>filter your whole history as you type, with matches highlighted.</p>
</li>
<li>
<span class="box-grid-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M12 21C12 21 18 14.5 18 9.5C18 5.9 15.3 3 12 3C8.7 3 6 5.9 6 9.5C6 14.5 12 21 12 21Z"></path>
<circle cx="12" cy="9.5" r="2.3"></circle>
</svg>
</span>
<h3>Pinned favorites</h3>
<p>keep what you reuse most a keystroke away, in a dedicated Pinned tab.</p>
</li>
<li>
<span class="box-grid-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M11 3H5C3.9 3 3 3.9 3 5V11C3 11.5 3.2 12 3.6 12.4L11.6 20.4C12.4 21.2 13.6 21.2 14.4 20.4L20.4 14.4C21.2 13.6 21.2 12.4 20.4 11.6L12.4 3.6C12 3.2 11.5 3 11 3Z"></path>
<circle cx="7.5" cy="7.5" r="1.5"></circle>
</svg>
</span>
<h3>Snippets with keyword expansion</h3>
<p>Save reusable text under a short Tag, then expand it by keyword in any app with ⌥⌘E.</p>
</li>
<li>
<span class="box-grid-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M2 12C2 12 5.5 5 12 5C18.5 5 22 12 22 12C22 12 18.5 19 12 19C5.5 19 2 12 2 12Z"></path>
<circle cx="12" cy="12" r="3"></circle>
</svg>
</span>
<h3>Optional on-device OCR</h3>
<p>recognize the text in copied screenshots with Apple's Vision framework, off by default. See the trade-off on the <a href="{{ "/privacy/" | relative_url }}">Privacy page</a> before turning it on.</p>
</li>
</ul>

</div>
</section>

<section class="section">
<div class="shell" markdown="1">

<div class="section-head" markdown="1">

## How it compares

A quick, honest look at Clipnest next to Maccy (the established free, open-source option) and Deck (a newer, feature-dense native competitor). A tick means the product has that feature as of September 2026; a blank cell means it doesn't.

</div>

<div class="table-scroll compare-table" markdown="1">

| Feature | Clipnest | Maccy | Deck |
|---|---|---|---|
| Open source (unrestricted license) | ✓ | ✓ | |
| Pinning | ✓ | ✓ | |
| Snippets / text expansion | ✓ | | ✓ |
| On-device OCR | ✓ | | ✓ |
| Fast, native Swift — no Electron | ✓ | ✓ | ✓ |

</div>

Sources: [p0deje/Maccy](https://github.com/p0deje/Maccy) and its [README](https://github.com/p0deje/Maccy/blob/master/README.md); [yuzeguitarist/Deck](https://github.com/yuzeguitarist/Deck), its [README](https://github.com/yuzeguitarist/Deck/blob/main/README.md), and [LICENSE](https://github.com/yuzeguitarist/Deck/blob/main/LICENSE). More on Clipnest's own pricing, privacy, and permissions in the [FAQ]({{ "/faq/" | relative_url }}).

</div>
</section>

<section class="section learn-grid">
<div class="shell" markdown="1">

## Learn more

- [Features]({{ "/features/" | relative_url }}) — everything Clipnest does, in detail.
- [FAQ]({{ "/faq/" | relative_url }}) — pricing, privacy, permissions, and more.
- [Privacy]({{ "/privacy/" | relative_url }}) — exactly what stays on your Mac.

</div>
</section>
