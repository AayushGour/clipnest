# Clipnest — Competitive Analysis

This file has two independent parts, kept together because they're both "how does the field
solve this" research for the same product:

- **Part A — macOS feature/market analysis** (Sept 2026, business-analyst/product-engineer pass).
  Unchanged from the prior revision; still accurate as a macOS competitor scan, still cited.
- **Part B — Linux clipboard-manager technical analysis** (2026-09-07, product-engineer pass).
  New. Answers a specific brief: how do CopyQ, GPaste, Diodon, xfce4-clipman, Parcellite/ClipIt,
  KDE Klipper, and GNOME Shell extensions (Pano, GPaste's own extension) actually solve the six
  hardest problems in Clipnest's Linux port, verified against primary source where the claim is
  checkable (upstream repos, Mutter's own GitLab, GNOME's own developer discourse) rather than
  blog-post paraphrase.

---

# Part A — macOS market analysis (Sept 2026)

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

**Verified against the code (2026-09-03, `main` @ 881b84d), not the README** — at that commit, the
README's roadmap was stale and still listed the Settings window as unbuilt. Settings live in
`ClipnestApp/Sources/UI/Settings/` (5 tabs) backed by `ClipnestApp/Sources/System/SettingsStore.swift`;
launch-at-login is `LaunchAtLoginController` (SMAppService); retention maps to `RetentionCap` in
`ClipnestCore`. **Update (2026-09-06): the README has since been fixed** (commit 4fb0c15) — its Roadmap
now checks off the Settings window and the feature list/§ Settings section both describe it in full, so
this is no longer a live gap between the README and the code; kept here only as the historical record of
what this analysis's own verification pass found.

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
- Windows / Linux. The pitch is "feels like part of macOS". **(Superseded — see Part B: a Linux port
  now exists and is well underway. This line is kept as the historical record of the original call.)**
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

**Update (2026-09-07, Part B):** OCR shipped for real on the Linux port (on-device PP-OCRv5 via ONNX
Runtime, see Part B §4/§5 below) faster than it did on macOS. The macOS `Vision`-based version above is
still unshipped as of this revision — worth re-prioritizing now that the harder (no-`Vision`-API) Linux
version already exists and the reading-order/space-decoding logic is proven out.

---

## 5. Positioning

The README undersold Clipnest as of this analysis's 881b84d verification point (it advertised the
Settings window as unbuilt) — since fixed in commit 4fb0c15, see §1's 2026-09-06 update. Clipnest's line
should be:

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

---

# Part B — Linux clipboard-manager technical analysis (2026-09-07)

## Scope and method

Clipnest's Linux port (`Sources/ClipnestPlatformLinux`, `Sources/ClipnestLinuxAppKit`,
`Sources/ClipnestGTK`, `Sources/ClipnestLinuxOCR`, `extension/`, `packaging/linux/`) is a real,
substantial GTK4 app already — not a stub. This section checks its six hardest, highest-risk design
calls against what established Linux clipboard managers actually ship, using primary sources wherever a
claim is checkable: upstream repos via DeepWiki, raw GitHub/GitLab source fetched directly, and one
GNOME-developer discourse thread. Every claim below cites a repo + file + function, or is flagged as
inference where it isn't checkable.

**Verdict up front, because it matters for how to read what follows:** Clipnest's Linux port is not
naively diverging from the field. On the two places I was asked to check most skeptically — the
XWayland selection bridge and the Shell-extension paste path — Clipnest's own code independently arrived
at the *same* underlying mechanism the two most relevant prior-art projects (GPaste, Pano) use, and in
one respect (streaming `Meta.Selection.transfer_async` instead of `St.Clipboard.get_text`) is more
capable than either. The real gap in both cases isn't the design, it's that neither has ever been
exercised against a real Mutter/GNOME Shell — see §1 and §2's "independent read" call-outs.

---

## 1. Wayland clipboard capture

**The premise is correct: Mutter implements neither protocol.** Confirmed from a live GNOME/KDE
maintainer exchange, not a blog post — a Red Hat Bugzilla thread on cross-desktop clipboard breakage
(#2016563) has a KDE developer stating plainly: *"There is no clipboard monitoring standard, we [Plasma]
are using `wlr-data-control-unstable-v1.xml` from wlroots and I can imagine that GTK didn't bother with
it."* That is the whole story in one sentence: **KWin implements `wlr-data-control-unstable-v1`; Mutter
does not implement it or `ext-data-control-v1`.**

**What a *native* GNOME Wayland client can see, with zero privilege, is: nothing.** From
`discourse.gnome.org/t/how-to-intercept-clipboard-operations-on-linux-wayland-mutter-gnome/19315`
(Feb 2024) — a GNOME core developer (mcatanzaro) answering a "how do I watch clipboard changes on
Mutter/Wayland" question directly: *"What you're trying to do is intentionally not permitted (since the
clipboard often contains sensitive data). You will need to (a) patch mutter, or (b) switch back to
X11."* Nobody in that thread mentions an XWayland-selection-bridge trick as a sanctioned third option —
telling, see the independent read below. A second reply in the same thread gives the one privileged
escape hatch that *does* exist: from **inside** a GNOME Shell extension,
`global.display.get_selection().connect('owner-changed', …)` plus `St.Clipboard` does see every change,
because the extension runs in-process with the compositor.

**What the field actually ships, confirmed per-project:**

| Project | Wayland/GNOME strategy | Source |
|---|---|---|
| **GPaste** (`Keruspe/GPaste`) | Daemon (`gpaste-daemon`) picks `GpasteX11Manager` or `GpasteWaylandManager` by `WAYLAND_DISPLAY`, **but** `GpasteWaylandManager` (`src/daemon/gpaste-wayland-manager.c`) does not itself read clipboard content. The real capture on Wayland is 100% inside the **mandatory** GNOME Shell extension: `GPasteClipboardManager` (`src/gnome-shell/extension.js`) hooks `St.Clipboard.get_default()`'s `clipboard`/`primary` `owner-changed` signals and relays text to the daemon via a D-Bus `Add()` call. **Without the extension installed and enabled, GPaste's Wayland history capture does not work at all** — verified via DeepWiki against the actual source. |
| **Pano** (`oae/gnome-shell-pano`, the most commonly cited GNOME-Wayland clipboard manager) | Not a companion app at all — it **is** the GNOME Shell extension. Its `ClipboardManager` hooks `global.get_display().get_selection()`'s `owner-changed` signal directly, watching both `Meta.SelectionType.SELECTION_CLIPBOARD` and `SELECTION_PRIMARY`. |
| **KDE Klipper** (`KDE/plasma-workspace`) | No workaround needed at all: KWin natively implements `wlr-data-control-unstable-v1` (per the Bugzilla thread above), so Klipper just uses the standard protocol via `KWayland::Client` on Wayland the same way it'd use X11 selections on X11. |
| **CopyQ** (`hluk/CopyQ`) | Genuinely native Wayland support exists (`WaylandClipboard`, `src/platform/x11/systemclipboard/waylandclipboard.cpp`, using `zwlr_data_control_manager_v1`) — for compositors that implement it (wlroots-based: Sway, etc.). On GNOME specifically, since Mutter doesn't implement that protocol, CopyQ's own code **forces `QT_QPA_PLATFORM=xcb`** so it runs entirely under XWayland rather than attempt native Wayland; `docs/known-issues.rst` lists clipboard monitoring/pasting/global shortcuts as broken "under a Wayland window manager" outside that forced-XWayland mode. |
| **Diodon** | "Only partial Wayland support" — in the maintainer's own words (Oliver Sauder, July 2026, esite.ch): *"it is based on the old GTK3 framework and relies on Zeitgeist which is not really developed anymore… I actually myself moved away to a different clipboard manager which only works on GNOME"* — i.e. the maintainer of a legacy X11-first clipboard manager personally gave up and switched to an extension-based one. |
| **xfce4-clipman, Parcellite, ClipIt** | Xfce's own Wayland compositor story (Wayfire/Labwc) is itself early; the Xfce community's own forum reports clipman "doesn't have focus, so not usable" there. Realistically X11-only in practice today. |

**So the field has exactly three real strategies, not four:** (a) force XWayland entirely and don't even
try native Wayland (CopyQ on GNOME), (b) ship a mandatory GNOME Shell extension that does the
compositor-privileged read (GPaste, Pano — the only two with unconditional native-Wayland capture on
GNOME), (c) partial/give up (Diodon, Xfce tools).

**What Clipnest does today.** Neither (a) nor (b) exclusively — it does a fourth, more surgical thing:
`LinuxPasteboard` (`Sources/ClipnestPlatformLinux/Clipboard/LinuxPasteboard.swift`) opens its own X11
connection and watches the `CLIPBOARD` selection via XFixes, on the strength of the claim (stated in that
file's own doc comment) that *"mutter re-owns the X11 `CLIPBOARD` selection on every
`MetaSelection::owner-changed`, including native-Wayland copies… with no Shell extension required."*
Separately, `extension/` ships a full, well-engineered GNOME Shell extension (`app.clipnest.ShellHelper1`)
whose `ClipboardWatcher` (`extension/src/core/clipboard.js`) hooks
`global.display.get_selection()`'s `owner-changed` signal directly — the *same* primitive Pano and
GPaste's extension use — and additionally supports `Meta.SelectionType.SELECTION_PRIMARY`, and streams
payloads via `Meta.Selection.transfer_async` into a socket pair rather than `St.Clipboard.get_text`
(text-only) — a genuinely more capable read path than either prior-art extension, since it isn't limited
to text.

**Independent verification I ran, not assumed.** The `LinuxPasteboard` doc comment's claim is the single
most load-bearing fact in this whole port, and it had **no verification trail anywhere** — no log entry,
no cited Mutter source, just an assertion. I checked it against Mutter's real source
(`gitlab.gnome.org/GNOME/mutter`, `src/x11/meta-x11-selection.c`):

- `meta_x11_selection_init()` connects `notify_selection_owner()` to `MetaSelection`'s `"owner-changed"`
  signal, for **every** selection type (`for (i = 0; i < META_N_SELECTION_TYPES; i++)`), and
  `notify_selection_owner()`'s own comment says exactly what Clipnest's doc comment claims: *"If the
  owner is non-X11, claim the selection on our selection window, so X11 apps can interface with it"* —
  followed by a real `XSetSelectionOwner()` call.
- **The claim is TRUE, verified against primary source, and it is a deliberate, actively-maintained
  compatibility feature** (this is `main` HEAD), not an accidental side effect. GNOME cannot remove it
  without breaking basic X11-app-pastes-Wayland-content interop, which makes it a durable foundation to
  build on.
- **One thing Clipnest's own doc comment undersells:** the loop covers `META_SELECTION_PRIMARY` too, not
  just `META_SELECTION_CLIPBOARD`. Clipnest could pick up X11 PRIMARY-selection (middle-click) capture —
  which Pano treats as a first-class feature — via the exact same XFixes mechanism it already has, for
  close to zero additional cost. Flagging as a cheap opportunity, not filing it as a task myself.
- **One real exposure this surfaces that wasn't previously flagged:** `meta_x11_selection_init()` only
  runs while a `MetaX11Display` (i.e. XWayland) exists. GNOME has been moving toward optional/lazy/
  disableable XWayland for hardened sessions; on a hypothetical GNOME Wayland session with XWayland
  disabled outright, this bridge — and therefore Clipnest's entire zero-extension capture path — would
  not exist. Not a near-term risk (XWayland-off is not a default anywhere yet), but worth a one-line
  fallback note in `docs/architecture.md` so it isn't a surprise later.
- Also worth naming plainly: Clipnest's XWayland-bridge path and its Shell-extension path are **not two
  independent, redundant strategies** — both are downstream of the exact same one Mutter-internal
  `MetaSelection::owner-changed` signal, observed from two different vantage points (X11 selection
  reflection vs. direct in-process GJS hook). If that upstream signal itself has a gap, both of
  Clipnest's paths inherit it together.

**My independent read on "relying on the XWayland bridge for Wayland capture" (the thing you asked me to
be blunt about).** This is not a hack and not an outlier — verified against Mutter's own source, it's
the correct, intended, GNOME-sanctioned interop surface, and it get Clipnest something **neither GPaste
nor Pano can claim: working clipboard-history capture on stock GNOME Wayland with zero extension
installed.** That is a genuine advantage over the two most comparable prior-art projects, not a
liability. The actual risk is narrower than "is this the right mechanism" — it's "has anyone ever run it
against a real compositor." Per `packaging/linux/vnc/Dockerfile`'s own header comment, the project's
Docker/VNC test harness explicitly proves plain X11 (Xvfb + openbox, no Mutter) clipboard capture, and
explicitly cannot exercise a real Mutter/GNOME-Shell session (containers have no systemd/logind/seat).
**That means the Wayland-specific half of this claim — Mutter actually re-owning a *native Wayland
client's* copy, not an X11 client's — has never been empirically observed on this project, only reasoned
from Mutter's source.** Recommendation: **adopt** (the mechanism is right, keep it as the zero-extension
default) but **investigate/de-risk before calling it done**: get one real run on an actual GNOME Wayland
session (a physical machine, a cloud desktop VM, or a GNOME Shell CI image with a real seat — a container
cannot do this) that copies from a native-Wayland GTK4 app (e.g. `gnome-text-editor`) and confirms
Clipnest's XFixes watcher actually sees it. This is a half-day spike, not a redesign, and it's the single
highest-value verification this whole port is missing.

---

## 2. Paste injection

**The field's actual norm, and it's not what the brief's framing implies: most established Linux
clipboard managers don't auto-paste at all.** Confirmed per-project:

- **GPaste**: no auto-paste support found anywhere in the codebase (DeepWiki, checked directly) —
  selecting a history item only updates the clipboard; the user presses the paste shortcut themselves.
- **KDE Klipper** (`KDE/plasma-workspace`): confirmed the same — selecting an item calls
  `setClipboardContents`, which only updates `SystemClipboard::Clipboard`/`::Selection`; there is no
  simulated keypress anywhere in the source.
- **CopyQ** is the outlier that *does* auto-paste, and only on X11: `X11PlatformWindow::pasteClipboard()`
  simulates `Ctrl+V` or `Shift+Insert` via XTEST (`sendKeyPress()`, gated on `HAS_X11TEST`) into the
  previously-focused window. Its own `docs/known-issues.rst` lists this as broken under native Wayland,
  with the only documented workaround being the forced-XWayland mode from §1.
- **Pano** is the one project that gets real native-Wayland auto-paste working, and how it does it is the
  key data point: `paste-on-select` (opt-in setting) simulates `Ctrl+V` via
  `Clutter.get_default_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE)`
  — a **compositor-privileged virtual input device**, only obtainable because Pano's code runs *inside*
  gnome-shell itself. A confined, external app has no equivalent privilege without either raw
  `/dev/uinput` access or a compositor-hosted helper doing the same Clutter call on its behalf.
- **ydotool is the real ecosystem answer for "how do external apps type on Wayland,"** and it's
  used well beyond clipboard managers — e.g. the dictation app OpenWhispr's own setup guide
  (`github.com/OpenWhispr/openwhispr` issue #310) walks through installing `ydotool`+`ydotoold`, a udev
  rule for `/dev/uinput`, and a systemd user service, because Ubuntu's `ydotool` package ships none of
  that by default. **The permission model the ecosystem actually tells users to use is worse than
  Clipnest's own**: the OpenWhispr guide (and multiple other ydotool setup guides found) tell the user to
  `usermod -aG input $USER` — the built-in `input` group, which — as Clipnest's own
  `packaging/linux/udev/clipnest-uinput.rules` comment correctly points out — also grants **read** access
  to every `/dev/input/event*` node, i.e. a full keylogging capability, not just the ability to create a
  virtual device. Clipnest's dedicated `clipnest-input` group (write-only to `/dev/uinput`, never `input`)
  is measurably *more* careful than what the wider ecosystem tells its own users to do.

**What Clipnest does today.** `LinuxEventSynthesizerFactory.makeDefault` already tries, in order:
(1) `/dev/uinput` directly via `UInputDevice` (no `ydotool`/`ydotoold` dependency at all — Clipnest is its
own in-process "ydotool"), (2) XTEST on an X11 session (`XTestEventSynthesizer`, explicitly refusing
itself on Wayland — `SessionType.detect` treats unknown as Wayland, fail-closed, so it never
silently no-ops against a native Wayland window), (3) `NullClipboardOnlyEventSynthesizer` — copy-only,
matching exactly what GPaste/Klipper do as their *entire* strategy. The polkit/udev grant machinery
(`packaging/linux/polkit/app.clipnest.grant-input.policy`, `packaging/linux/scripts/clipnest-grant-input`,
`packaging/linux/udev/clipnest-uinput.rules`) is real, security-conscious (PKEXEC_UID-only, dedicated
group, no keylogging surface), and — verified by grep — **wired to zero UI**: nothing in
`Sources/ClipnestGTK` or `Sources/ClipnestLinuxAppKit` ever mentions `pkexec`, `grant-input`, or
`clipnest-input`. A user who installs the `.deb` has no way to grant themselves the group short of
running `pkexec clipnest-grant-input` from a terminal by hand — which defeats the entire point of a GUI
settings flow, and there is also no visible state in Settings showing "auto-paste is available/blocked."
The extension's `InputSynthesizer` (`extension/src/core/input.js`) independently implements the exact
same `Clutter.VirtualInputDevice` mechanism Pano uses — confirming the design already matches the one
proven native-Wayland approach in the wild, with an extra safety property (`focusAndSendChord` focuses
and sends in one compositor main-loop turn, closing a focus-move race the macOS `Paster` equivalent
can't close).

**Recommendation.**
- **Adopt** the current priority order (uinput → XTEST → clipboard-only) — it already matches or beats
  the field; nobody else combines direct uinput with a fail-closed Wayland/XTEST gate this cleanly, and
  Clipnest doesn't need to shell out to a separate `ydotool`/`ydotoold` process at all, which sidesteps
  the version-skew and missing-systemd-unit problems that plague `ydotool` in practice.
  **Do not adopt XTEST-on-XWayland-forced-mode (CopyQ's approach)** — it would give up the GTK4-native
  Wayland UI Clipnest already has for a worse, off-brand fallback that the field itself documents as
  degraded.
- **Diverge deliberately, and be honest about it in the UI copy**, on "always attempt auto-paste": given
  that GPaste and Klipper — two of the most-used clipboard managers in this survey — ship *copy-only* as
  their entire paste story, "content is on the clipboard, press Ctrl+V" is not a degraded experience by
  field standards, it's the majority default. Treat `NullClipboardOnlyEventSynthesizer` as a first-class,
  respectable outcome in copy, not just an error path.
- **Fix now, cheaply:** wire the existing, already-secure `clipnest-grant-input` polkit flow into a
  Settings → Permissions control ("Auto-paste needs one-time setup" → a button that shells out to
  `pkexec clipnest-grant-input`, matching the polkit dialog's own copy) plus a startup check (is the
  process's own UID in `clipnest-input`? Is `/dev/uinput` present/loaded?) so users on the uinput path
  get told when they've silently landed on the copy-only fallback instead of guessing. This is a UI-only
  task on top of code that already exists and is already reviewed for security — the single
  highest-value-per-line-of-code Linux fix in this whole report.

---

## 3. Per-row actions and the picker UI

**Field convention, per project:**
- **CopyQ**: main-window rows, `F2` to edit, `Delete` to remove, tray-menu activation, plus a full
  scripting API (`plugins.itempinned.pin()/unpin()`, `plugins.itemtags`) for anything beyond the built-ins
  — this is CopyQ's whole identity (a scriptable power tool), not a convention to copy.
- **Pano**: a `PanoItemHeader` per item exposing a favorite/pin icon button plus keyboard shortcuts
  (`Delete` to remove, `Ctrl+S` to favorite) — i.e. the same "icon button(s) on the row + keyboard
  shortcut" shape Clipnest already uses, not a hover-only or menu-only convention. No dedicated "edit."
- **Klipper / GPaste**: minimal — list + remove; no per-item edit surface found.

**What Clipnest does today.** `ItemRowActionContent.swift` / `SnippetRowActionContent.swift`
(`Sources/ClipnestGTK/Window/`) implement three always-visible trailing icon buttons (pin/unpin, save-
as-snippet, delete) **plus** a right-click `GtkPopover` context menu (`PickerWindow+ContextMenu.swift`)
offering the same three actions plus a menu-only fourth ("Copy Recognized Text") — explicitly built as a
"Linux parity pass" mirroring the macOS `ItemRow` design, with gating logic shared between both surfaces
so no action is wired twice. This is a recent, deliberate addition (there was previously *zero*
right-click menu in the Linux picker at all, per that file's own commit-time grep confirmation).

**Recommendation: adopt as-is, this is not an outlier.** Icon-button-per-row plus a right-click menu with
the same actions is both (a) what the one comparable native-GNOME clipboard manager in this survey
(Pano) does, and (b) consistent with modern GTK4/libadwaita row conventions (suffix action widgets on
list rows), so there's no "macOS convention forced onto Linux" problem here to fix. The one gap worth
naming: none of the field examples researched here support **edit-in-place** for a clip (CopyQ's `F2` is
the closest, and it's part of a much bigger scripting surface) — if Clipnest ships edit-before-paste per
the macOS roadmap (Part A, Tier 1 item 8), it would be ahead of the Linux field on this specific point,
not just at parity.

---

## 4. OCR

**Nobody in this survey does on-device OCR of copied images.** Confirmed explicitly negative for CopyQ
and GPaste (checked directly against source via DeepWiki); no evidence found for Klipper, Diodon,
xfce4-clipman, Parcellite/ClipIt; explicitly confirmed negative for Pano (*"Pano does not perform Optical
Character Recognition (OCR) on copied images… computes a checksum, saves it to disk, extracts width/
height/size"* only). The nearest adjacent prior art is **screenshot tools, not clipboard managers**:
`apex-shot/apexshot` (a Linux screenshot/annotation app, not a history manager) ships "dual-engine OCR"
using **Tesseract** (installed as a system package with separate language-data packages — the universal
Linux convention, e.g. `tesseract-ocr-eng`) plus **ocrs/rten** (`robertknight/ocrs`, a Rust OCR engine).

**How the closest analogue (`ocrs`) actually distributes its weights, and why it matters directly for the
question asked:** verified via DeepWiki against the real source — `ocrs-cli` **downloads models on first
run** into `~/.cache/ocrs` from a fixed S3 URL (`ModelSource::Url`, `download_file`), because it's a
standalone CLI tool with no packaging pipeline of its own. Its **browser extension**, by contrast — the
one distribution shape that has to be a complete, offline-installable artifact at submission time —
**vendors the `.rten` model files directly into the extension build** (`ocrs-extension/README.md`
instructs copying `text-detection.rten`/`text-recognition.rten` into the build's `models/ocr` directory).
That split is the generalizable finding: *download-on-first-use is what OSS tools do when there's no
formal package to put the weights in; vendoring is what happens the moment the artifact has to be a
complete, offline-installable unit* — which a `.deb` is, and which Debian/Ubuntu archive and Launchpad
PPA policy actively prefer (no reaching out to a third-party host during `postinst`, reproducible builds).
This also matches Tesseract's own long-established Debian convention of shipping trained data as
**separate packages** (`tesseract-ocr-eng`, `tesseract-ocr-deu`, …) so users who don't need OCR — or a
given language — don't pay for it.

**What Clipnest does today.** `Sources/ClipnestLinuxOCR/` is a from-scratch ONNX Runtime pipeline for
PP-OCRv5 (detection + text-line classifier + CRNN recognition + CTC decode), gated behind a
`clipnest-ocr-data` **separate `.deb`** from the main `clipnest` package
(`packaging/linux/vendor/ppocr-models/README.md` documents the exact four required files —
`det.onnx`/`rec.onnx`/`cls.onnx`/`dict.txt` — totaling ~22MB, matching `ModelLocating.swift`'s
`/usr/share/clipnest-ocr/models/` paths exactly). `debian/rules` fails the build loudly rather than
shipping an empty/broken data package if the files are missing — currently blocking, per that README's
own "NOT VENDORED YET" heading, on sourcing pinned files + SHA-256 + a real `debian/copyright` license
stanza (deliberately not filled with a placeholder — a prior `lintian` run flagged
`missing-license-paragraph-in-dep5-copyright` for that).

**Recommendation: adopt vendoring via a separate data package — this is already the right call, not a
question mark.** It matches (a) the field's own "vendor when the artifact must be offline-installable"
split found in `ocrs`, (b) Debian's own established multi-package convention for language/model data
(Tesseract), and (c) this project's own existing precedent (`packaging/linux/vendor/onnxruntime/` is
already vendored, versioned, and documented the same way). The size (~22MB) is unremarkable by Debian
data-package standards. **This also means Clipnest would ship the first on-device OCR of copied
images among Linux clipboard *history managers* in this survey** — the closest things that do OCR at
all are screenshot tools, not clipboard managers, so this is genuine white space, not a "why hasn't
anyone done this" red flag. The only action item is the one already tracked: source the exact pinned
PP-OCRv5 ONNX exports + SHA-256 + license text and finish `packaging/linux/vendor/ppocr-models/`
per its own README's own "What needs to happen next" list — that's a devops/architect task, not a new
finding from this research pass.

---

## 5. Reading order and spacing in OCR output

Verified directly against PaddleOCR's own upstream source (`PaddlePaddle/PaddleOCR`, GitHub, `main`
branch, fetched raw), not paraphrase — both of Clipnest's suspected bugs are real, and both have an exact
upstream reference implementation to match.

### 5a. The dropped space (18385 model classes vs. 18383-line dict)

`ppocr/postprocess/rec_postprocess.py`, `BaseRecLabelDecode.__init__`:
```python
for line in lines:
    line = line.decode("utf-8").strip("\n").strip("\r\n")
    self.character_str.append(line)
if use_space_char:
    self.character_str.append(" ")          # <-- space appended HERE, after the dict file's lines
dict_character = list(self.character_str)
```
and `CTCLabelDecode.add_special_char`:
```python
def add_special_char(self, dict_character):
    dict_character = ["blank"] + dict_character   # <-- blank prepended at index 0
    return dict_character
```
So the model's real class list, index 0 to N, is **`["blank"] + <dict file's N lines> + [" "]`** — length
`N + 2`. `char_num = len(post_process_class.character)` is literally what sizes the recognition head's
`out_channels` at training time, so this ordering is load-bearing, not cosmetic.

Clipnest's `CharacterDictionary.parse` (`Sources/ClipnestLinuxOCR/Recognition/CharacterDictionary.swift`)
loads only the raw dict file — `N` entries, no appended space — and `CTCDecoder.greedyDecode`
(`Sources/ClipnestLinuxOCR/Recognition/CTCDecoder.swift`) maps class index `i` to `dictionary[i - 1]`
(accounting for the blank at 0) with a bounds check `dictIndex < dictionary.count`. For the space class
(the model's highest index, `N + 1`), `dictIndex = N`, and `dictionary.count == N` — so `N < N` is false,
and the character is **silently dropped** by the exact bounds check that exists to make corrupt output
fail safe rather than crash. This is precisely the 18385-vs-18383 report: `N = 18383`.

**Recommendation — adopt PaddleOCR's own ordering exactly, this is not a design choice, it's a
correctness bug with one exact fix:** append a single `" "` entry to the parsed dictionary array
(matching `self.character_str.append(" ")`'s position — after the file's lines, before nothing else) so
`dictionary.count` becomes `N + 1` and the space class's `dictIndex == N` resolves correctly. This is a
one-line change in `CharacterDictionary.parse` (or its caller), fully unit-testable without touching
`CTCDecoder` at all.

### 5b. Scrambled word order (single bubble pass vs. real insertion sort)

`tools/infer/predict_system.py`, `sorted_boxes` (fetched verbatim):
```python
def sorted_boxes(dt_boxes):
    num_boxes = dt_boxes.shape[0]
    sorted_boxes = sorted(dt_boxes, key=lambda x: (x[0][1], x[0][0]))
    _boxes = list(sorted_boxes)
    for i in range(num_boxes - 1):
        for j in range(i, -1, -1):
            if abs(_boxes[j + 1][0][1] - _boxes[j][0][1]) < 10 and (
                _boxes[j + 1][0][0] < _boxes[j][0][0]
            ):
                tmp = _boxes[j]
                _boxes[j] = _boxes[j + 1]
                _boxes[j + 1] = tmp
            else:
                break
    return _boxes
```
This is a **real insertion sort**: the outer loop walks forward once, but the **inner loop walks
backward from `i` to `0`, with an early `break` the moment two boxes are NOT swapped** — i.e. a box can
propagate arbitrarily far up the list within its row, not just one slot. DeepWiki's read of the same
function (cross-checked against the fetched source above, which matches) confirms this is intentionally
insertion-sort-shaped, and that PaddleOCR's own Kotlin/Swift/C++/JS ports (`sortInReadingOrder`,
`SortQuadBoxes`, etc.) all replicate the identical two-step shape — i.e. every downstream consumer
matches this exactly, none simplifies it.

Clipnest's `BoxOrdering.sortReadingOrder`
(`Sources/ClipnestLinuxOCR/Detection/BoxOrdering.swift`) does the same initial sort, then **a single
fixed-index adjacent pass** (`for i in 0..<(sorted.count - 1) { compare/swap sorted[i], sorted[i+1] }`) —
one swap per position, no backward propagation, no `break`. For two boxes on the same row this is
equivalent; for **three or more** boxes on one visual row whose initial `(y, x)` sort put them out of
left-to-right order by more than one position (common — y-jitter of a few pixels between glyphs on the
same baseline routinely reorders the `x`-sort key), Clipnest's pass fixes at most one adjacent inversion
and leaves the rest scrambled. This is exactly the "scrambled word order" symptom reported.

**Recommendation — adopt PaddleOCR's exact algorithm, not a "close enough" single pass:** replace the
one bubble pass with the same bounded insertion sort (outer `for i in 0..<count-1`, inner loop walking
backward from `i` down to `0` with early exit on the first non-swap). This is a small, self-contained,
easily property-tested change (generate N boxes with jittered y and reversed-x within a row; assert final
order is monotonic left-to-right per row) — no change to `Quadrilateral`, `BoxScaling`, or anything
upstream of ordering.

---

## 6. Packaging and distribution

**Field convention:** CopyQ ships **`.deb` + an official Ubuntu PPA + Flathub Flatpak** (confirmed no
official Snap/AppImage). GPaste and Klipper ship as ordinary **distro packages** (Debian/Fedora
repositories) with no extra sandboxed-format story found. Diodon's maintainer explicitly commits to
**keeping it in Debian/Ubuntu archives** as the one thing he'll still maintain, even in "low maintenance
mode" — archive presence, not a fancy format, is what he treats as the load-bearing distribution
guarantee. Autostart, universally, is the XDG Autostart spec (`~/.config/autostart/*.desktop`) — no
project does anything bespoke here.

**What Clipnest does today.** `.deb` with a proper `debian/` tree (postinst creates the `clipnest-input`
group, compiles GSettings schemas, reloads udev, `modprobe uinput`, all best-effort/idempotent — a
genuinely careful postinst), plus a Launchpad PPA push gated on a GPG secret
(`.github/workflows/release-linux.yml`), matching CopyQ's own `.deb`+PPA half exactly. Autostart is a
standard XDG `.desktop` drop (`AutostartDesktopFile.swift`) — correct, no divergence. **No Flatpak or
Snap manifest exists in the repo today.**

**Recommendation.**
- **Adopt**: `.deb` + PPA is the right primary channel and matches the most comparable prior art
  (CopyQ) exactly; no change needed.
- **Investigate further before adopting Flatpak, don't default to "just add it":** Flatpak's sandbox is
  a real complication here, not a free win, because the auto-paste story depends on raw `/dev/uinput`
  access — a Flatpak app doesn't get that without either a `--device=all`-class manifest override (which
  Flathub review would reasonably push back on for a clipboard-history app) or falling back to copy-only
  inside the sandbox, silently degrading the one feature Clipnest is trying hardest to get right on
  Linux. If Flatpak is pursued later (for the reach — Flathub is a real discovery channel CopyQ
  benefits from), scope it explicitly as "Flatpak build = copy-only by design" rather than trying to
  thread privileged-uinput access through the sandbox.
- **No Snap** — no comparable project in this survey ships one; not worth the packaging-format tax for a
  discovery channel nobody else here uses.

---

## Answering the two things you specifically wanted an independent read on

**"Relying on the XWayland bridge for Wayland capture."** Verified against Mutter's own GitLab source
(`src/x11/meta-x11-selection.c`): this is real, intentional, actively-maintained GNOME behavior, not a
fragile side effect, and it gives Clipnest a genuine edge over GPaste and Pano — the two most comparable
prior-art projects — neither of which can capture anything on Wayland without their extension installed
and enabled. **My read: keep it as the default, zero-extension path.** The actual weakness isn't the
mechanism, it's that the Wayland-specific half of the claim (does Mutter really re-serve a *native*
Wayland client's copy, not just an X11 one) has literally never been observed running — the project's own
test harness structurally cannot exercise it (no real Mutter/seat in a container). That's a one-time,
half-day verification spike against a real GNOME Wayland session, not a redesign.

**"Shipping a Shell extension as the recommended path when it's never been dispatched by a real
Mutter."** Independently reading the extension's actual code (`extension/src/core/clipboard.js`,
`service.js`, `input.js`) before forming an opinion: the design is not a guess. It correctly reimplements
the exact mechanism (`Meta.Selection`'s `owner-changed` signal) that GPaste's own extension and Pano both
use for capture, and the exact mechanism (`Clutter.VirtualInputDevice`) that Pano — the only project in
this survey with working native-Wayland auto-paste — uses for injection. It is, if anything, more
carefully built than either (streaming binary transfer instead of text-only `St.Clipboard`; atomic
focus-and-send in one compositor turn to close a race the macOS `Paster` can't close). **The concern is
legitimate, but it's a verification-status problem, not a design problem** — and the project's own
`extension/README.md` already says so explicitly ("Verification status — read before assuming this has
run for real… no method here has ever been dispatched by a real GNOME Shell"), which is the right
instinct already in place. My addition: don't let "optional, adds capabilities" framing (which
`extension/README.md`'s own comparison table already uses, sensibly) drift into "recommended path" in any
user-facing doc or install script until it has cleared at least one real dispatch against an actual
Mutter/GNOME Shell — a nested `gnome-shell --nested` session on a real (non-container) Linux desktop, or
a cloud GNOME-Wayland VM, is the cheapest way to get that; a plain container structurally cannot, per
this project's own Dockerfile comment.

---

## Condensed recommendations

| # | Area | Verdict | Action |
|---|---|---|---|
| 1 | Wayland clipboard capture | **Adopt** the XWayland-bridge default (verified correct against Mutter source); **investigate**: run one real capture test against a live GNOME Wayland session before treating it as proven | Half-day spike on real hardware/VM; consider adding PRIMARY-selection capture (same mechanism, ~free) |
| 2 | Paste injection | **Adopt** uinput→XTEST→clipboard-only priority as-is; it beats the field's own `ydotool`+`input`-group norm on security | Wire the already-built, already-secure `clipnest-grant-input` polkit flow into a Settings UI — currently zero UI callers |
| 3 | Per-row actions | **Adopt** as-is — matches Pano and modern GTK4 row conventions, not an outlier | None required |
| 4 | OCR | **Adopt** vendoring via a separate `clipnest-ocr-data` .deb — matches Debian/Tesseract convention and `ocrs`'s own offline-artifact precedent | Source pinned PP-OCRv5 ONNX files + SHA-256 + license (already tracked in `packaging/linux/vendor/ppocr-models/README.md`) |
| 5 | OCR reading order / spacing | **Adopt** PaddleOCR's exact upstream algorithms — both current bugs are proven, single-file, well-scoped fixes | Append `" "` to the parsed dict (`CharacterDictionary`); replace the single bubble pass with the real backward insertion sort (`BoxOrdering`) |
| 6 | Packaging | **Adopt** `.deb` + PPA (matches CopyQ); **investigate further, don't default to yes** on Flatpak given the uinput-sandbox conflict | No action needed now; scope any future Flatpak as copy-only by design |

## What surprised me

- **GPaste — a widely-packaged, Debian/Fedora-archive clipboard manager — has *zero* clipboard capture on
  Wayland without its own Shell extension enabled.** Not degraded, not partial: nothing. That reframes
  the whole brief's premise; a Shell-extension dependency for Wayland isn't a Clipnest-specific risk, it's
  the price of entry the entire GNOME ecosystem pays, and Clipnest's XWayland-bridge fallback means it
  already does *better* than GPaste's no-extension case.
- **Diodon's own maintainer, in a live July 2026 post, said he personally abandoned his own project's
  approach for a Shell-extension-based one.** That's about as strong a real-world verdict on "which
  architecture actually works on GNOME Wayland" as this research turned up.
- **The one thing everyone assumes is "the norm" — `ydotool`-style auto-paste — is actually the
  exception.** GPaste and Klipper, two of the most-used names in this space, are copy-only by design.
  Clipnest is already more ambitious than most of the field here, not behind it.
- **Nobody who is actually a clipboard *history manager* does OCR.** The only prior art is screenshot
  tools. Shipping it is genuine white space, not a "why hasn't this been done" red flag — and the
  packaging precedent (`ocrs`'s CLI-downloads-on-first-run vs. extension-vendors-at-build-time split)
  independently validates Clipnest's existing vendor-a-separate-`.deb` decision.
- **Mutter's XWayland selection-bridge behavior is real, intentional, and durable** — verified against
  its actual GitLab source rather than taken on faith — which was the single most valuable thing to
  check directly, since the entire Linux Wayland story rests on it and it had no verification trail
  anywhere in the project before this pass.
