---
layout: page
title: "Frequently Asked Questions — Clipnest"
description: "Answers to common questions about Clipnest: pricing, privacy, supported macOS versions, snippets, OCR, permissions, and how it compares to other clipboard managers."
permalink: /faq/
---

<details class="faq-item" markdown="1">

<summary markdown="1">

## Is Clipnest free and open source?

</summary>

<div class="faq-answer" markdown="1">

Yes. Clipnest is free with no paid tier, no account, and no in-app purchases, and it's released under the [MIT license](https://github.com/AayushGour/clipnest/blob/main/LICENSE) — the full source is on [GitHub](https://github.com/AayushGour/clipnest) for anyone to read, fork, or modify. There's no trial, no feature gate, and nothing held back for a future paid version.

</div>

</details>

<details class="faq-item" markdown="1">

<summary markdown="1">

## Does Clipnest send my clipboard data anywhere?

</summary>

<div class="faq-answer" markdown="1">

No. Everything you copy, paste, or save as a snippet stays on your Mac — there are no servers, no sync, no analytics, and no telemetry. The one narrow exception is a background check against GitHub's public Releases API (about once a day, and you can turn it off in Settings → General) to see whether a newer version exists; it sends nothing about you or your clipboard, just an anonymous request for the latest release tag. See the [Privacy page]({{ "/privacy/" | relative_url }}) for the full picture, including the one trade-off (OCR) covered below.

</div>

</details>

<details class="faq-item" markdown="1">

<summary markdown="1">

## Will updating Clipnest make me re-grant Accessibility permission?

</summary>

<div class="faq-answer" markdown="1">

No — that's the point of how Clipnest is signed. Every Clipnest release is signed with the same long-lived certificate, and macOS ties an Accessibility grant to the app's designated code identity, which stays stable across releases signed with the same certificate. Many apps that rebuild or resign with a new identity between versions invalidate your grant on every update, sending you back to System Settings to re-add the app by hand. Clipnest is built specifically to avoid that — update it and Accessibility keeps working, no re-grant needed.

</div>

</details>

<details class="faq-item" markdown="1">

<summary markdown="1">

## Why does macOS say Clipnest is from an "unidentified developer"? Is it notarized?

</summary>

<div class="faq-answer" markdown="1">

Clipnest is **not** notarized with a paid Apple Developer ID, and if you download its `.dmg` straight from a browser, macOS's Gatekeeper will show the "unidentified developer" warning. The supported install path avoids this entirely: `scripts/install.sh` (the one-line curl command on the [Download page]({{ "/download/" | relative_url }})) downloads over `curl`, which never sets the quarantine flag that triggers that Gatekeeper check in the first place — instead, the script verifies the `.dmg` against a published SHA-256 checksum before ever mounting it. Every release is still signed, just with one long-lived, self-signed certificate rather than a Developer ID — enough to keep your Accessibility grant stable across updates (see above), but not enough on its own to satisfy notarization. Clipnest is v0.9.0 and about a month old; if you'd rather wait for a fully notarized, Gatekeeper-clean build, that's on the roadmap but not shipped yet.

</div>

</details>

<details class="faq-item" markdown="1">

<summary markdown="1">

## How is Clipnest different from macOS 26 Tahoe's built-in clipboard history?

</summary>

<div class="faq-answer" markdown="1">

Tahoe's built-in history (Spotlight, ⌘Space then ⌘4) is opt-in, keeps items for 8 hours by default (configurable from 30 minutes up to 7 days as of macOS 26.1), and lets you search and clear what you've copied — but it can't pin favorites, organize anything, save a snippet, or expand text by keyword. Clipnest picks up from there: history that doesn't quietly age out, a dedicated Pinned tab, and reusable snippets that expand by keyword in any app.

</div>

</details>

<details class="faq-item" markdown="1">

<summary markdown="1">

## How is Clipnest different from Maccy and Deck?

</summary>

<div class="faq-answer" markdown="1">

Compared to Maccy (a well-established free, open-source clipboard manager), Clipnest adds snippets with keyword expansion, optional on-device OCR, and a full Settings window, at the cost of being brand new rather than battle-tested since 2018. Compared to Deck (a newer, feature-dense native competitor), Clipnest is a smaller, more focused app under a plain MIT license, rather than Deck's source-available terms. Neither comparison is one-sided — Maccy's pinning and years of hardening, and Deck's regex/semantic search and automatic OCR, are real advantages on their side; see the [feature table on the home page]({{ "/" | relative_url }}) for a quick, sourced side-by-side.

</div>

</details>

<details class="faq-item" markdown="1">

<summary markdown="1">

## What is the on-device OCR feature, and why is it off by default?

</summary>

<div class="faq-answer" markdown="1">

Clipnest can optionally read the text inside a copied screenshot, entirely on your Mac, using Apple's Vision framework — no upload, no model download, no network call. It's off by default because turning it on means that recognized text becomes indexed and searchable alongside the image, so a screenshot containing a password or anything else sensitive turns that content into searchable text on disk. Turn it on in Settings → History only if you're comfortable with that trade-off; it's a Fast/Accurate choice once enabled, and it never runs on anything the privacy filter already excludes (password-manager copies, excluded apps).

</div>

</details>

<details class="faq-item" markdown="1">

<summary markdown="1">

## What macOS versions does Clipnest support?

</summary>

<div class="faq-answer" markdown="1">

macOS 14 (Sonoma) or later, on both Apple Silicon and Intel Macs.

</div>

</details>

<details class="faq-item" markdown="1">

<summary markdown="1">

## Does Clipnest capture images and files, or just text?

</summary>

<div class="faq-answer" markdown="1">

All of the above. Clipnest automatically captures plain text, rich text, URLs, images, and files as you copy them, and you can filter the history down to just one type with a click. Copied images also get an optional recognized-text badge if OCR is turned on (see above).

</div>

</details>

<details class="faq-item" markdown="1">

<summary markdown="1">

## What are snippets, and how does keyword expansion work?

</summary>

<div class="faq-answer" markdown="1">

A snippet is reusable text you write yourself — a signature, boilerplate reply, or command — saved with a short **Tag**. Type that Tag in any app, select it, and press a hotkey (⌥⌘E by default); Clipnest replaces the selection with the snippet's full body. It works the same way in native apps and in Electron/Chrome-based ones like VS Code or Slack, using the Accessibility API where it can and a clipboard-snapshot-and-restore fallback where it can't. If you're running a separate text expander today, this is meant to replace it.

</div>

</details>

<details class="faq-item" markdown="1">

<summary markdown="1">

## How much clipboard history does Clipnest keep?

</summary>

<div class="faq-answer" markdown="1">

By default, the most recent 1,000 items. You can switch that to a day-based cap (30 days by default) or turn retention off entirely and keep everything, with no limit. Pinned items are always kept regardless of the cap, and you can wipe your whole history at any time from Settings.

</div>

</details>
