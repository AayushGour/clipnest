# Clipnest — Competitive Analysis (Sept 2026)

Market scan of macOS clipboard managers, Clipnest's gaps, and a ranked feature roadmap to win.
Sources: vendor sites (Tapbots, Paste, Raycast, ClipBook, Cliptop, SaneClip, ClipTop, OneNotch, Klipto),
comparison roundups (Lifehacker, Zapier, TypeFire, Klipto, OneNotch), Apple Support (Tahoe Spotlight).

---

## 1. The market in one paragraph

The floor moved. **macOS 26 Tahoe ships a native clipboard history** (Spotlight → ⌘4), off by default,
~8 hours to 7 days retention, no organization. That kills "I just want my last few copies" as a paid
proposition and squeezes the low end. Above it sit three tiers:

| Tier | Apps | Price | What they sell |
|---|---|---|---|
| Free / OSS | **Maccy**, Clipy, Flycut, CopyQ | $0 | history + search, nothing else |
| Cheap lifetime | **ClipBook** ($9.99+), **Cliptop** ($19.99), **SaneClip** ($14.99), PastePal ($14.99), OneNotch ($9.99), Klipto ($19.99), CleanClip ($12.99), PasteNow ($7.99) | $8–20 once | OCR, transforms, sync, stacks |
| Premium / power | **Paste** ($29.99/yr or $89.99), **Pastebot 3** ($39 + $19/yr), **Raycast Pro** ($8–10/mo), **Alfred Powerpack** (~£34) | recurring or high one-time | ecosystem sync, automation, filter chains |

Clipnest sits in tier 1 (free, MIT, native) but ships tier-2 features (snippets + keyword expansion,
hover previews, type filters). That is the wedge — it is currently under-claimed.

---

## 2. Competitor profiles

### Maccy — the OSS incumbent to displace
Free, MIT, macOS 14+. History + fast search, pins, paste plain, ignore apps / pasteboard types,
tooltip previews, configurable poll interval, i18n. **No** snippets, no expansion, no rich previews,
no type filters, no OCR, no sync. Biggest asset: mindshare — every roundup's "free pick".

### Paste — the ecosystem play
$29.99/yr or $89.99 lifetime. Mac + iPhone + iPad, private iCloud sync, **pinboards**, Power Search
with **OCR inside images**, iOS keyboard. Sells "your clipboard library, everywhere". Weakness: price,
subscription fatigue, heavy.

### Pastebot 3 (Tapbots, July 2026) — the power tool
$39 + $19/yr (or $24.99/yr MAS). macOS 26 only. **Stackable filter chains** (reusable text transforms,
real-time preview, per-filter hotkeys), **Smart Pastebins** (rule-based auto-organization), **Sequential
Paste stacks** (⌃⌘V), Quick Paste menu (⇧⌘V + number keys), per-clipping shortcuts, **CLI helper**,
iCloud sync Mac↔Mac, app blacklist. Weakness: Mac-only, expensive, Tahoe-only.

### Raycast — the bundled competitor
Free / Pro $8–10/mo. Clipboard inside the launcher: text/images/colors/links/files, **on-device OCR
(Fast vs Accurate)**, link previews (favicons + social cards), QR decode, edit-before-paste, format
conversion (rich↔plain↔RTF↔HTML), excluded apps, retention 1 day→unlimited (long retention is Pro),
bulk delete by time window, **"Ask Clipboard" AI** (summarize/translate recent clips). Weakness: you
must adopt the whole launcher; no device sync.

### ClipBook — the value power-user pick
$9.99+ lifetime, source-available. Unlimited history with retention choice, text/image/file/link/**color**/email,
**text-in-image search**, tags + custom names, filter by type/tag/**source app**, **78 text transforms**,
**merge multiple clips with separators**, **split multi-line clips**, sequential paste without opening the
window, **⌘1-9 quick paste**, import/export, themes, sounds, pause, app exclusions. Local-only, no sync.
This is the closest "feature superset" rival to where Clipnest is headed.

### Cliptop — the AI/semantic angle
$9.99/yr or $19.99 lifetime. **Semantic search** (find by meaning), on-device OCR, snippets **with
variables**, private iCloud sync + iPhone/iPad, pinboards, URL tracking-parameter stripping, markdown
link generation, image crop, sensitive-item blurring.

### SaneClip — the privacy/automation OSS-ish rival
$14.99 lifetime, PolyForm Shield (source-available, not OSS). AES-256-GCM encrypted history, **Touch ID
lock**, sensitive-data detection (cards, SSNs, API keys), app exclusions, **App Intents + Shortcuts actions**
(get history, paste, search, clear, list/paste snippets), `saneclip://` URL scheme, **paste stack (FIFO/LIFO)**,
transforms, **snippets with `{{date}}` / `{{clipboard}}` placeholders**, tags/collections, source color-coding,
auto-expiry, free iOS companion.

### Emerging / niche
- **PastePaw** (Aug 2026) — ships a **local MCP server** so AI agents can read clipboard history. First mover on agent integration.
- **UniClipboard** — OSS, P2P **E2E-encrypted clipboard sync** across Mac/Win/Linux/iOS/Android, no account, no server. Sync only, not a manager.
- **OneNotch** — clipboard in the notch, copy stack, OCR, $9.99 lifetime.
- **Espanso / TextExpander / Snippety** — the text-expansion side Clipnest already partly occupies: dynamic placeholders (date/time/clipboard), cursor placement, forms, shell output.

---

## 3. Feature matrix — Clipnest vs the field

Legend: ✅ has · ⚠️ partial · ❌ missing

| Capability | Clipnest | Maccy | Paste | Pastebot 3 | Raycast | ClipBook | Cliptop | SaneClip |
|---|---|---|---|---|---|---|---|---|
| History: text/rich/image/file/link | ✅ | ⚠️ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Colors as a type | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Instant search + highlight | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **OCR / text-in-image search** | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Semantic / fuzzy search | ❌ | ⚠️ | ⚠️ | ❌ | ⚠️ | ❌ | ✅ | ❌ |
| Filter by source app | ⚠️ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Type filters | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| Pins / favorites | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Folders / pinboards / tags | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| Rich hover previews | ✅ | ⚠️ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| Paste plain text | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Quick paste ⌘1-9** | ❌ | ⚠️ | ✅ | ✅ | ❌ | ✅ | ❌ | ❌ |
| **Sequential paste / stack** | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ | ✅ |
| **Text transforms / filter chains** | ❌ | ❌ | ⚠️ | ✅ | ⚠️ | ✅ | ⚠️ | ✅ |
| Merge / split clips | ❌ | ❌ | ❌ | ⚠️ | ❌ | ✅ | ❌ | ❌ |
| Edit clip before paste | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| Snippets | ✅ | ❌ | ✅ | ✅ | ✅ | ⚠️ | ✅ | ✅ |
| **Snippet variables/placeholders** | ❌ | ❌ | ⚠️ | ✅ | ✅ | ❌ | ✅ | ✅ |
| Keyword expansion in any app | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ⚠️ |
| Excluded apps | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Pause capture | ✅ | ⚠️ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Retention config | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Launch at login | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Custom hotkeys | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Shortcuts / App Intents** | ❌ | ❌ | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | ✅ |
| CLI | ❌ | ❌ | ❌ | ✅ | ⚠️ | ❌ | ❌ | ⚠️ |
| **MCP / AI-agent access** | ❌ | ❌ | ❌ | ❌ | ⚠️ | ❌ | ❌ | ❌ |
| AI actions on clips | ❌ | ❌ | ⚠️ | ❌ | ✅ | ❌ | ⚠️ | ❌ |
| Cross-device sync | ❌ | ❌ | ✅ | ⚠️ Mac↔Mac | ❌ | ❌ | ✅ | ✅ |
| iOS app | ❌ | ❌ | ✅ | ❌ | ⚠️ | ❌ | ✅ | ✅ |
| Encryption at rest / Touch ID | ❌ | ❌ | ⚠️ | ❌ | ❌ | ❌ | ⚠️ | ✅ |
| Import / export / backup | ❌ | ❌ | ⚠️ | ⚠️ | ❌ | ✅ | ❌ | ❌ |
| Auto-update | ⚠️ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Free + true OSS (MIT) | ✅ | ✅ | ❌ | ❌ | ❌ | ⚠️ | ❌ | ⚠️ |
| Price | **$0** | $0 | $29.99/yr | $39 | $8-10/mo | $9.99 | $19.99 | $14.99 |

**Where Clipnest already wins:** free + MIT + native SwiftUI + cursor-anchored non-activating panel +
snippets with **system-wide keyword expansion** (AX-first with clipboard-restore fallback) + rich hover
previews + honoring concealed/transient pasteboard markers + a **full Settings window already shipped**
(General: launch-at-login, pause capture, daily update check · History: retention unlimited / N items /
N days + clear-all · Apps: user exclusion list on top of the built-in password-manager denylist ·
Shortcuts: rebind both global hotkeys · Permissions). No free competitor has that combination — Maccy
has none of the snippet/expansion story.

**Verified against the code (2026-09-03, `main` @ 881b84d), not the README** — the README's roadmap is
stale and still lists the Settings window as unbuilt. Settings live in `ClipnestApp/Sources/UI/Settings/`
(5 tabs) backed by `ClipnestApp/Sources/System/SettingsStore.swift`; launch-at-login is
`LaunchAtLoginController` (SMAppService); retention maps to `RetentionCap` in `ClipnestCore`.

**Where Clipnest is actually behind:**

| Gap | State today | Notes |
|---|---|---|
| Auto-update | ⚠️ partial | `UpdateChecker` does a 24h availability check (curl → GitHub Releases) and shows a dot; `AppUpdater.runUpdate()` then opens **Terminal** with `curl \| bash`. No in-app download/install, no Sparkle. |
| Gatekeeper | ⚠️ optional | `release.yml` signs/notarizes only if Developer ID secrets exist; the default path is a self-signed release cert with quarantine stripped. |
| Source-app filter | ⚠️ data exists, no UI | `ClipItem.sourceAppName` / `.sourceBundleID` are **already captured** (`ClipboardMonitor`) and used for exclusions — but never shown on a row, never a filter, and the search predicate (`SwiftDataClipStore.query`) only matches `normalizedText`. |
| Quick paste by number | ❌ | ⌘1/2/3 are taken by tab switching (`PickerView.handle`), so this needs ⌃1-9 or ⌥1-9. |
| Paste stack / sequential | ❌ | — |
| Text transforms | ❌ | — |
| Snippet variables | ❌ | `Snippet` = id/title/body/keyword/createdAt. No placeholders. |
| Edit / merge / split clips | ❌ | — |
| Tags, collections, folders | ❌ | Only the single Pinned scope. |
| Search inside images (OCR) | ❌ | See §4a — there is a cheap way to do this. |
| Shortcuts / App Intents, CLI, MCP | ❌ | — |
| Colors as a kind | ❌ | `ItemKind` = text / richText / link / image / file. |
| Sync, iOS, encryption at rest | ❌ | — |

---

## 4. Ranked roadmap

### Tier 0 — finish what is nearly done
1. **In-app update (Sparkle) + Developer ID notarization.** Biggest remaining table-stakes gap. Today's
   flow — "we open Terminal and run `curl \| bash` for you" — is fine for the GitHub crowd and a hard
   stop for everyone else. Every rival, including free Maccy, updates itself silently.
2. **Surface the source app.** The data is already in the store; this is a UI-only change: app icon on
   each row, a "from <App>" filter, and add `sourceAppName` to the search predicate. Highest
   value-per-line-of-code item on this list. Universal in tier 2/3, absent in Maccy.
3. **Quick paste by number** — ⌃1-9 (⌘1-3 are tabs) from the open picker.
4. **README/roadmap refresh.** The shipped Settings window is invisible to anyone evaluating Clipnest
   from its README, which is where every comparison-roundup author looks.

### Tier 1 — parity where it is cheapest for a native app
5. **Sequential paste / Paste Stack** (⌃⌘V, FIFO + LIFO). Pastebot's most-praised feature; ClipBook,
   SaneClip, OneNotch all have it. Pure logic on top of the existing store — no new system surface.
6. **Text transforms as a stackable chain** — trim, case, slugify, JSON pretty, strip HTML, unescape,
   base64, URL-encode, join lines, regex replace — with live preview and per-transform hotkeys. ClipBook
   ships 78 flat; ~20 well-chosen ones **that chain** beats 78 that don't. Fits `ClipnestCore` as a pure,
   fully unit-testable module — zero runtime cost when unused.
7. **Snippet variables** — `{{date}}`, `{{time}}`, `{{clipboard}}`, `{{cursor}}`, `{{input:label}}`.
   Clipnest already owns expansion; variables turn it into a real text expander and swallow the
   Espanso / TextExpander use case for free. Cheap: one templating pass inside `SnippetExpander`.
8. **Edit-before-paste**, **merge selected clips with a separator**, **split a multi-line clip into items**.
9. **Tags / collections** beyond the single Pinned tab.
10. **Colors as a kind** — small; `ItemKind.color` + a swatch in `ItemRow`. Everyone else has it.

### Tier 2 — the differentiators nobody free owns
11. **MCP server (local, opt-in, scoped).** Expose history + snippets to Claude Code / Cursor / any agent
    over a local MCP endpoint, with per-collection scoping and a redaction rule set. PastePaw (paid,
    Aug 2026) is the only mover. For a dev-audience OSS app on GitHub this is the strongest single wedge
    available. Ship it behind an explicit consent gate + audit log — it is a sensitive-data surface, and
    it is also the one feature that would put a network listener in an app whose whole pitch is
    "no network calls at all" (bind loopback-only, off by default, say so loudly).
12. **CLI (`clipnest`)** — `list`, `get N`, `copy`, `paste`, `snippet expand <tag>`, `--json`. Trivial on
    top of `ClipnestCore`, pairs with the MCP server, exactly what the GitHub audience wants. Only
    Pastebot has one.
13. **Shortcuts / App Intents actions** — get history, paste item, search, save snippet, expand snippet, clear.
14. **Encryption at rest + Touch ID lock** + blurred previews for sensitive-looking clips. Upgrades the
    privacy story from "local" to "local and protected", which is the brand. SaneClip charges $14.99 for it.
15. **On-device semantic search** — only if §4a's cost test passes; same objection as OCR applies
    (embedding every clip is a per-capture compute cost). Lower priority than 11-14.

### Tier 3 — big bets
16. **P2P E2E-encrypted sync (no account, no server)** — Bonjour / local network, keys pinned per device.
    This is Paste's and Cliptop's only real moat, and doing it with **no cloud account** is a story neither
    can tell. Large effort; needs an iOS app to fully matter.
17. **iOS/iPadOS companion + keyboard.** Only after 16.
18. **Rule-based auto-organization** ("URLs copied from Xcode → this collection") — Pastebot's Smart Pastebins.

### Deliberately skip
- Subscription / licensing plumbing. Free + MIT **is** the position; GitHub Sponsors at most.
- Windows / Linux. The pitch is "feels like part of macOS".
- Always-on background indexing of any kind (see §4a).

---

## 4a. On OCR — the resource objection, and the cheap way to do it

You pushed back on OCR because Clipnest sells "featherweight". Correct instinct, but the cost is smaller
than it looks, and it is fully controllable. The numbers matter because **OCR is the single most-cited
feature in every 2026 roundup** (Paste, Raycast, ClipBook, Cliptop, OneNotch, TypeFire all lead with it),
and it is the one thing Spotlight's native history cannot do.

**What it actually costs.** `Vision.VNRecognizeTextRequest` with `.recognitionLevel = .fast` and
`usesLanguageCorrection = false`, on Apple Silicon, runs on the GPU/ANE — roughly tens to a couple hundred
ms for one screenshot-sized image, once. It is **not** a background daemon, not an index that rebuilds,
and not a steady-state cost: nothing runs unless an image is copied. Output is a few KB of text appended
to the existing `normalizedText`, so search comes free through the current predicate and the DB barely grows.

**The real risk** is doing it eagerly on every capture: someone copying large images in a loop gets a
burst of GPU work and battery drain, which is exactly the reputation Clipnest is avoiding.

**Recommended shape — three dials, cheapest default first:**

1. **On-demand only (default, zero background cost).** An "Extract Text" action in the item's context menu
   and preview. Raycast ships exactly this as an explicit action. Cost when unused: literally zero.
   This alone lets the README say "search inside your screenshots" honestly.
2. **Deferred + opt-in for automatic indexing.** A Settings → History toggle, default **off**: "Search text
   inside images". When on, OCR runs on a `.utility` QoS task, coalesced, only while the app is idle,
   skipping while on battery below a threshold. `SettingsStore` already has the shape for one more key.
3. **Cap the work.** Downscale to ~1600px on the long edge before the request, skip images above a
   pixel/byte ceiling, `.fast` level, no language correction, one-shot per `contentHash` (the blob store is
   already content-addressed, so a re-copied image never OCRs twice).

Net: Clipnest gets the headline feature every paid rival charges for, and the idle cost stays at exactly
what it is today. If even (1) feels wrong, ship (1) and never ship (2) — the marketing line survives either way.

**Same test applies to semantic search (§4 item 15) and AI actions** — both are per-clip compute. Semantic
embedding is heavier than OCR and benefits far fewer users; leave it below MCP/CLI in priority, and if it
ships, ship it on the same opt-in, deferred, idle-only terms. Cloud AI actions should stay out entirely:
they'd break the "no network calls at all" claim, which is worth more than the feature.

---

## 5. Positioning

The README undersells — it still advertises the Settings window as unbuilt. Clipnest's line should be:

> **The free, open-source clipboard manager that also replaces your text expander.**
> Native SwiftUI, opens at your cursor, remembers exactly as much as you tell it to, and never touches
> the network.

Against each rival:
- **vs Tahoe Spotlight** — retention you control instead of ~8 hours, snippets + expansion, rich previews, pins, paste straight back into the field you were in.
- **vs Maccy** — everything Maccy does, plus snippets with system-wide keyword expansion, rich previews, type filters, and a real Settings window.
- **vs Paste / Pastebot / Raycast Pro** — most of the features, $0, MIT, no account, no subscription, no launcher lock-in.

Add "searches inside your screenshots" to that pitch only once §4a item (1) ships.

**Sequencing recommendation:** Tier 0 (1–4, mostly polish + Sparkle) → paste stack + transforms (5–6) →
snippet variables (7) → **MCP + CLI (11–12) as the flagship differentiator release** → on-demand OCR
(§4a item 1) whenever it fits, since it is a small, self-contained action.

---

## 6. What changed in this revision (2026-09-03)

First pass was written from the README and overstated Clipnest's gaps. Re-verified against `main` @ 881b84d:

- **Settings window is shipped** — 5 tabs, covering launch-at-login, pause capture, retention (unlimited /
  N items / N days), clear-all, per-app exclusions, hotkey rebinding, permissions, update-check toggle.
  Removed from the roadmap; five matrix cells corrected from ❌ to ✅.
- **Auto-update downgraded ❌ → ⚠️** — a 24h availability check exists; the install step still shells out
  to Terminal. Sparkle is still the gap.
- **Source-app filter downgraded ❌ → ⚠️** — the fields are already captured and stored; only the UI and
  the search predicate are missing. Effort estimate dropped accordingly.
- **OCR moved out of Tier 1** into §4a with an explicit cost analysis and an on-demand-by-default design,
  per the "must stay featherweight" constraint.
