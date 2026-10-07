---
layout: article
title: Privacy — Clipnest is 100% Local, No Cloud, No Telemetry
description: Clipnest never sends your clipboard data anywhere. No servers, no sync, no telemetry, no account — see exactly what stays on your Mac or Linux PC and the OCR trade-off, honestly.
permalink: /privacy/
---

# Privacy

Your clipboard is some of the most sensitive data on your machine — passwords, tokens, private messages. Clipnest treats it that way.
{: .lead}

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<rect x="3" y="4" width="18" height="12" rx="2"></rect>
<line x1="8" y1="20" x2="16" y2="20"></line>
<line x1="12" y1="16" x2="12" y2="20"></line>
</svg>
</div>

## 100% local, with one narrow exception

</div>

Nothing you copy, paste, or save as a snippet is ever sent anywhere — no servers, no sync, no analytics, no telemetry, no account.

The *only* network traffic Clipnest ever makes is a background check against GitHub's public Releases API, once a day, to see whether a newer version exists. You can turn it off in **Settings → General**. That check sends nothing about you or your clipboard — just an anonymous request for the latest release tag — and nothing downloads or installs automatically because of it; updating stays a separate step you choose to run yourself (on Linux, after you confirm **Install Update…**). See [Update on Mac]({{ '/download/#update-on-mac' | relative_url }}) and [Update and uninstall on Linux]({{ '/download/#update-and-uninstall-on-linux' | relative_url }}) for those flows.

Your history and snippets are stored only on your own disk: on the Mac in `~/Library/Application Support/Clipnest`, on Linux in `~/.local/share/Clipnest` (or `$XDG_DATA_HOME/Clipnest` if you set that).

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M2 12C2 12 5.5 5 12 5C18.5 5 22 12 22 12C22 12 18.5 19 12 19C5.5 19 2 12 2 12Z"></path>
<circle cx="12" cy="12" r="3"></circle>
</svg>
</div>

## On-device OCR: opt-in, and a real trade-off — stated plainly

</div>

Turn on **"Recognize text in copied images"** (Settings → History, **off by default**) and Clipnest reads the text in a screenshot right on your computer — with Apple's Vision framework on the Mac, or on Linux with the ONNX Runtime and PP-OCRv5 models installed by the `clipnest-ocr` packages — no upload, no model download, no network call of any kind.

<div class="notice" markdown="1">

But that recognized text becomes plain, searchable text stored alongside the image. So a screenshot of a password, a token, or anything else sensitive turns that content into indexed text on disk. **That's exactly why this is off by default** — turn it on only if you're fine with that trade-off.

</div>

It never runs on anything the pasteboard-privacy checks below already rejected: concealed/transient (password-manager) copies and content from excluded apps are filtered out before an item is even captured, so on-device text recognition never sees them either. See [Features]({{ '/features/' | relative_url }}) for the Mac's Fast/Accurate quality setting.

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<circle cx="7.5" cy="15.5" r="4.5"></circle>
<path d="M11 12L20 3"></path>
<path d="M16 7L19 10"></path>
<path d="M13 10L15.5 12.5"></path>
</svg>
</div>

## Password managers are ignored

</div>

Clipnest honors the standard "concealed" and "transient" clipboard markers that password managers set, so copies from 1Password, Bitwarden, and similar apps are never stored. No setting can override this.

On Linux the equivalent marker is `x-kde-passwordManagerHint` (set by KeePassXC and others). Those copies are never stored either, including the copy GNOME re-publishes after the password manager clears the clipboard.

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

## Linux permissions, and what they can see

</div>

Auto-paste on Linux needs one permission: it adds you to a dedicated `clipnest-input` group that can create a virtual keyboard and nothing else. It is deliberately **not** the `input` group, which could read your keystrokes. Without it, Clipnest still works; it copies your choice and you press Ctrl+V yourself. The optional GNOME Shell extension only changes where the picker window opens.

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M12 3L19 6V11C19 16 16 19.5 12 21C8 19.5 5 16 5 11V6L12 3Z"></path>
<path d="M9 12L11 14L15.5 9.5"></path>
</svg>
</div>

## No clipboard content in logs

</div>

Only metadata — things like an item's id or a failure's error case — is ever logged. Clipboard or snippet content is never written to a log.

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<line x1="4" y1="6" x2="20" y2="6"></line>
<line x1="4" y1="12" x2="20" y2="12"></line>
<line x1="4" y1="18" x2="20" y2="18"></line>
<circle cx="9" cy="6" r="2"></circle>
<circle cx="16" cy="12" r="2"></circle>
<circle cx="9" cy="18" r="2"></circle>
</svg>
</div>

## You're in control

</div>

Delete any entry on the spot, pause capture whenever you want, and clear your entire history in one click — all from **Settings**.

</div>
