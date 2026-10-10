---
layout: article
title: Download Clipnest for Mac and Linux (Free)
description: Download Clipnest free for macOS 14 Sonoma and later, or Ubuntu 22.04/24.04 with GNOME. Open source, no account required.
permalink: /download/
---

# Download Clipnest

Free, open source, no account, no cloud, no telemetry. One command installs it on your Mac or on Linux: it detects your system and installs the latest version.
{: .lead}

<section class="install-hero" aria-labelledby="install-heading" markdown="1">

## Install
{: #install-heading}

<div class="os-chips" aria-label="Works on">
<span class="os-chip">macOS</span>
<span class="os-chip">Linux</span>
</div>

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">macOS · Linux</b></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
```

</div>

<ul class="req-grid">
<li><strong>Mac</strong> macOS 14 (Sonoma) or later, Apple Silicon or Intel.</li>
<li><strong>Linux</strong> Ubuntu 22.04 or 24.04 with GNOME (X11 or Wayland), amd64 or arm64. Run it as your normal user; it asks for <code>sudo</code> to install.</li>
</ul>

</section>

<section class="steps-section" aria-labelledby="next-heading" markdown="1">

## What happens next
{: #next-heading}

<ol class="steps">
<li><span class="step-title">Install</span><span class="step-body">The script downloads the latest release and checks its SHA-256 before installing anything.</span></li>
<li><span class="step-title">Open</span><span class="step-body">Press <kbd>⌥⌘V</kbd> on a Mac or <kbd>Alt+Super+V</kbd> on Linux to open the picker.</span></li>
<li><span class="step-title">Paste</span><span class="step-body">Search or pick an item and press Return. Allow the one-time permission when asked so Clipnest can paste for you: Accessibility on a Mac, auto-paste on Linux.</span></li>
</ol>

<div class="note-linux" markdown="1">

**Linux: log out and back in once after granting auto-paste.** The permission only takes effect in a new session. Until you do, Clipnest copies the item you pick and you press <kbd>Ctrl+V</kbd> yourself. The same applies after installing the optional GNOME Shell extension.

</div>

</section>

<section class="steps-section" aria-labelledby="uninstall-heading" markdown="1">

## Uninstall
{: #uninstall-heading}

Same command with `uninstall.sh`. It removes the app and keeps your history, snippets and settings.

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">macOS · Linux</b></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/uninstall.sh | bash
```

</div>

To delete your data too, add `-s -- --purge` after `bash`.

</section>

<div class="cta-inline" markdown="1">

**Prefer to download it yourself?** Grab the `.dmg` or the Linux tarball from [GitHub Releases](https://github.com/AayushGour/clipnest/releases/latest). Manual steps, updating, environment variables and building from source are on the [Contribute page]({{ '/contribute/' | relative_url }}).
{: #signing-honestly}

On a Mac and wondering why there's no Gatekeeper warning? Read [Signing, honestly]({{ '/contribute/#signing-honestly' | relative_url }}).

</div>
