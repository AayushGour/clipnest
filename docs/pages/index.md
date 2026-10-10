---
layout: home
title: "Clipnest — Free, Open-Source Clipboard Manager for Mac and Linux"
description: "Clipnest is a free, open-source, native clipboard manager for macOS and Linux (Ubuntu with GNOME): full history, instant search, pins, and snippets that expand by keyword in any app."
permalink: /
---

<section class="hero-visual" aria-label="See Clipnest in action">
<div class="shell">
  <div class="demo-carousel">
  <div class="demo-tabs" role="tablist" aria-label="Clipnest demos">
    <button type="button" class="demo-tab" role="tab" id="demo-tab-0" aria-controls="demo-0" aria-selected="true">Copy &amp; paste</button>
    <button type="button" class="demo-tab" role="tab" id="demo-tab-1" aria-controls="demo-1" aria-selected="false" tabindex="-1">Text from images</button>
    <button type="button" class="demo-tab" role="tab" id="demo-tab-2" aria-controls="demo-2" aria-selected="false" tabindex="-1">Snippets</button>
    <button type="button" class="demo-tab" role="tab" id="demo-tab-3" aria-controls="demo-3" aria-selected="false" tabindex="-1">Settings</button>
  </div>
  <div class="shot-frame demo-stage">
    <figure class="demo-slide" id="demo-0" role="tabpanel" aria-labelledby="demo-tab-0">
      <div class="demo-video">
        <video muted playsinline autoplay loop preload="auto" poster="{{ "/assets/demos/01-copy-paste.jpg" | relative_url }}" width="1280" height="800" aria-label="Copy &amp; paste demo">
          <source src="{{ "/assets/demos/01-copy-paste.webm" | relative_url }}" type="video/webm">
          <source src="{{ "/assets/demos/01-copy-paste.mp4" | relative_url }}" type="video/mp4">
        </video>
      </div>
      <figcaption>Copy a few things, then press ⌥⌘V in any app and pick one to paste.</figcaption>
    </figure>
    <figure class="demo-slide" id="demo-1" role="tabpanel" aria-labelledby="demo-tab-1">
      <div class="demo-video">
        <video muted playsinline loop preload="none" poster="{{ "/assets/demos/02-ocr.jpg" | relative_url }}" width="1280" height="800" aria-label="Text from images demo">
          <source src="{{ "/assets/demos/02-ocr.webm" | relative_url }}" type="video/webm">
          <source src="{{ "/assets/demos/02-ocr.mp4" | relative_url }}" type="video/mp4">
        </video>
      </div>
      <figcaption>Copy an image and Clipnest reads its text on-device. Press ⌥⏎ to paste the text instead of the image.</figcaption>
    </figure>
    <figure class="demo-slide" id="demo-2" role="tabpanel" aria-labelledby="demo-tab-2">
      <div class="demo-video">
        <video muted playsinline loop preload="none" poster="{{ "/assets/demos/03-snippets.jpg" | relative_url }}" width="1280" height="800" aria-label="Snippets demo">
          <source src="{{ "/assets/demos/03-snippets.webm" | relative_url }}" type="video/webm">
          <source src="{{ "/assets/demos/03-snippets.mp4" | relative_url }}" type="video/mp4">
        </video>
      </div>
      <figcaption>Save text under a short keyword. Select the keyword anywhere and press ⌥⌘E to expand it.</figcaption>
    </figure>
    <figure class="demo-slide" id="demo-3" role="tabpanel" aria-labelledby="demo-tab-3">
      <div class="demo-video">
        <video muted playsinline loop preload="none" poster="{{ "/assets/demos/04-settings.jpg" | relative_url }}" width="1280" height="800" aria-label="Settings demo">
          <source src="{{ "/assets/demos/04-settings.webm" | relative_url }}" type="video/webm">
          <source src="{{ "/assets/demos/04-settings.mp4" | relative_url }}" type="video/mp4">
        </video>
      </div>
      <figcaption>Press ⌘, in the picker to open Settings and turn on text recognition for images.</figcaption>
    </figure>
  </div>
  </div>
</div>
</section>

<section class="cta-strip">
<div class="shell" markdown="1">

## Install in one line

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">macOS · Linux</b></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
```

</div>

**Mac:** macOS 14 (Sonoma) or later. **Linux:** Ubuntu 22.04 or 24.04 with GNOME (X11 or Wayland), amd64 or arm64. Run it as your normal user; on Linux it asks for `sudo` to install the packages. More on the [Download page]({{ "/download/" | relative_url }}).

</div>
</section>

<section class="section">
<div class="shell">

<div class="section-head" markdown="1">

## Why Clipnest?

macOS 26 Tahoe added a basic clipboard history to Spotlight (⌘4) — but it's opt-in, caps out at 7 days, and can't organize, pin, or expand anything. Clipnest is a free, open-source, native menu-bar app that picks up where that leaves off: history you control, instant search, pinned favorites, and reusable snippets that expand by keyword in any app.

**Now on Linux too.** Since 1.0, the same Clipnest runs on Ubuntu with GNOME, on X11 or Wayland — a native GTK 4 app built from the same Swift core, with the same history, search, pins, snippets, OCR and Settings.

</div>

<div class="feature-grid">

<div class="feature-card" markdown="1">

### The permission that doesn't disappear on update (Mac)

Update Clipnest and you don't have to re-grant Accessibility. Every release is signed with the same certificate, so the designated code identity macOS ties your permission grant to stays the same across versions — you're not sent back to System Settings after every update the way you are with apps that rebuild or re-sign between releases. Read the full, honest signing story on the [FAQ]({{ "/faq/" | relative_url }}).

</div>

<div class="feature-card" markdown="1">

### Free, open source, natively built

No Electron, no web view. Clipnest is a small, native Swift app — SwiftUI on the Mac, GTK 4 on Linux — released under the [MIT license](https://github.com/AayushGour/clipnest/blob/main/LICENSE), with the full source on [GitHub](https://github.com/AayushGour/clipnest). No account, no cloud, no telemetry. See exactly what stays on your computer on the [Privacy page]({{ "/privacy/" | relative_url }}).

</div>

<div class="feature-card" markdown="1">

### Snippets that expand anywhere you type

Save a signature, a boilerplate reply, or a command as a **snippet**, give it a short **Tag**, then type that Tag in *any* app and press a hotkey — Clipnest replaces it with the snippet's full body. On the Mac it works the same way in native Cocoa apps and in Electron/Chrome-based ones like VS Code or Slack; on Linux it works on both X11 and Wayland. If you're running a separate text expander alongside your clipboard manager today, this replaces it too. More on the [Features page]({{ "/features/" | relative_url }}).

</div>

</div>

</div>
</section>

<section class="section bento">
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
<p>Save reusable text under a short Tag, then expand it by keyword in any app with ⌥⌘E on the Mac or Alt+Super+E on Linux.</p>
</li>
<li>
<span class="box-grid-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M2 12C2 12 5.5 5 12 5C18.5 5 22 12 22 12C22 12 18.5 19 12 19C5.5 19 2 12 2 12Z"></path>
<circle cx="12" cy="12" r="3"></circle>
</svg>
</span>
<h3>Optional on-device OCR</h3>
<p>recognize the text in copied screenshots — with Apple's Vision framework on the Mac, a bundled ONNX Runtime and PP-OCRv5 models on Linux — entirely on your computer, off by default. See the trade-off on the <a href="{{ "/privacy/" | relative_url }}">Privacy page</a> before turning it on.</p>
</li>
</ul>

</div>
</section>

<section class="section">
<div class="shell" markdown="1">

<div class="section-head" markdown="1">

## How it compares

A quick, honest look at Clipnest next to Maccy (the established free, open-source option) and Deck (a newer, feature-dense native competitor). A tick means the product has that feature as of October 2026; a blank cell means it doesn't.

</div>

<div class="table-scroll compare-table" markdown="1">

| Feature | Clipnest | Maccy | Deck |
|---|---|---|---|
| Open source (unrestricted license) | ✓ | ✓ | |
| Pinning | ✓ | ✓ | |
| Snippets / text expansion | ✓ | | ✓ |
| On-device OCR | ✓ | | ✓ |
| Fast, native Swift — no Electron | ✓ | ✓ | ✓ |
| Runs on Linux | ✓ | | |

</div>

Sources: [p0deje/Maccy](https://github.com/p0deje/Maccy) and its [README](https://github.com/p0deje/Maccy/blob/master/README.md); [yuzeguitarist/Deck](https://github.com/yuzeguitarist/Deck), its [README](https://github.com/yuzeguitarist/Deck/blob/main/README.md), and [LICENSE](https://github.com/yuzeguitarist/Deck/blob/main/LICENSE). More on Clipnest's own pricing, privacy, and permissions in the [FAQ]({{ "/faq/" | relative_url }}).

</div>
</section>

<section class="cta-band">
<div class="shell" markdown="1">

## Ready to try Clipnest?

Free, open source, and a single command away on your Mac or Linux PC.

<div class="hero-cta">
<a class="btn btn-primary" href="{{ "/download/" | relative_url }}">Download Clipnest</a>
<a class="btn btn-secondary" href="{{ "/features/" | relative_url }}">See all features</a>
</div>

<p class="cta-links"><a href="{{ "/faq/" | relative_url }}">FAQ</a> · <a href="{{ "/privacy/" | relative_url }}">Privacy</a> · <a href="{{ "/contribute/" | relative_url }}">Contribute</a> · <a href="https://github.com/AayushGour/clipnest/blob/main/CHANGELOG.md">Changelog</a></p>

</div>
</section>
