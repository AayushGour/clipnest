---
layout: default
title: Privacy — Clipnest is 100% Local, No Cloud, No Telemetry
description: Clipnest never sends your clipboard data anywhere. No servers, no sync, no telemetry, no account — see exactly what stays on your Mac and the OCR trade-off, honestly.
permalink: /privacy/
---

# Privacy

Your clipboard is some of the most sensitive data on your machine — passwords, tokens, private messages. Clipnest treats it that way.

## 100% local, with one narrow exception

Nothing you copy, paste, or save as a snippet is ever sent anywhere — no servers, no sync, no analytics, no telemetry, no account.

The *only* network traffic Clipnest ever makes is a background check against GitHub's public Releases API, once a day, to see whether a newer version exists. You can turn it off in **Settings → General**. That check sends nothing about you or your clipboard — just an anonymous request for the latest release tag — and nothing downloads or installs automatically because of it; updating stays a separate, manual step you choose to run yourself. See [Update]({{ '/download/#update' | relative_url }}) for that flow.

## On-device OCR: opt-in, and a real trade-off — stated plainly

Turn on **"Recognize text in copied images"** (Settings → History, **off by default**) and Clipnest reads the text in a screenshot right on your Mac using Apple's Vision framework — no upload, no model download, no network call of any kind.

But that recognized text becomes plain, searchable text stored alongside the image. So a screenshot of a password, a token, or anything else sensitive turns that content into indexed text on disk. **That's exactly why this is off by default** — turn it on only if you're fine with that trade-off.

It never runs on anything the pasteboard-privacy checks below already rejected: concealed/transient (password-manager) copies and content from excluded apps are filtered out before an item is even captured, so on-device text recognition never sees them either. See [Features]({{ '/features/' | relative_url }}) for the Fast/Accurate quality setting.

## Password managers are ignored

Clipnest honors the standard "concealed" and "transient" clipboard markers that password managers set, so copies from 1Password, Bitwarden, and similar apps are never stored. No setting can override this.

## No clipboard content in logs

Only metadata — things like an item's id or a failure's error case — is ever logged. Clipboard or snippet content is never written to a log.

## You're in control

Delete any entry on the spot, pause capture whenever you want, and clear your entire history in one click — all from **Settings**.
