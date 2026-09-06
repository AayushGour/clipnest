# Clipnest SEO/AEO Plan — macOS only

Owner: architect. Size: **M**. Branch: `feat/seo-aeo-macos` (worktree `/Users/aayushgour/Desktop/projects/clipnest-seo`, cut from `main` @ b34f32c).

Goal: `github.com/AayushGour/clipnest` surfaces and gets cited when a human or an AI agent looks for a macOS clipboard manager. Repo today: 0 stars, 0 topics, generic description, no homepage, no site, no screenshots, v0.9.0, MIT, ~1 month old. Scope is **macOS only** — no Linux content, no cross-platform claims, anywhere (site copy, metadata, JSON-LD, robots.txt).

This plan synthesizes R1 (GitHub discovery), R2 (AEO/llms.txt/crawlers), R3 (site SEO mechanics), R4 (competitive/keywords), R5 (distribution channels), plus a direct read of README.md, docs/competitive-analysis.md, docs/usage.md, docs/features.md, Package.swift, and assets/clipnest-icons/. Every claim below that will ship as public copy has been checked against the actual repo state; anything I couldn't verify is flagged.

---

## 0. Resolutions of research disagreements / new findings

- **Swift Package Index: R5 is correct, R1 is superseded.** R1 assumed Clipnest was an app-only `Package.swift` and recommended skipping SPI. I read `Package.swift` directly: it defines `.library(name: "ClipnestCore", targets: ["ClipnestCore"])` with `platforms: [.macOS(.v14)]` — a genuine SwiftPM library product, independent of the `ClipnestApp` XcodeGen target. **Submit `ClipnestCore` to Swift Package Index.** Zero star/notability gate, per `SwiftPackageIndex/PackageList`'s own contributing doc (R5).
- **DeepWiki is still not indexed.** I called `mcp__deepwiki__read_wiki_contents` against `AayushGour/clipnest` directly during this planning pass (same call R1 made) and got the identical result: `"Repository not found. Visit https://deepwiki.com/AayushGour/clipnest to index it."` This confirms the MCP query tool does **not** itself trigger indexing (it's read-only against an already-built wiki) — indexing is triggered by an actual HTTP hit to the human-facing URL. Task below has devops `curl` that URL once and re-verify via the MCP tool.
- **`docs/competitive-analysis.md` is stale on a load-bearing fact.** It still frames OCR as unshipped / a future roadmap item (§4a). Per R4 §0, OCR is confirmed **already shipped** (`git log` shows `4fb0c15 feat: on-device OCR`, merged to `main`; README.md:35,63,183 documents it as real, off-by-default, Vision-based). This file must **not** be published as-is (see §4 below) — the site's comparison content is written fresh, fact-checked against the live app, not lifted from this doc.
- **The README's opening hook is now factually wrong, not just dated.** "macOS only remembers the last thing you copied" was true through macOS 25; **macOS 26 Tahoe ships an opt-in clipboard history in Spotlight (⌘4)** (30 min / 8 h / 7 day retention, no pins, no organization, no search-by-app, no OCR, no expansion — confirmed via R4 §0 against Cult of Mac / MacMost / Apple World Today / Paste's own reactive blog post). Every piece of copy this plan touches (README hook, Home page hero) uses the corrected framing in §5 below — this is a correctness fix per the brief, not optional polish.
- **`robots.txt` on a GitHub Pages *project* page has a real, non-obvious limitation, worth stating plainly so no one is surprised later.** The robots.txt spec (RFC 9309) is evaluated only at the **origin root** (`https://aayushgour.github.io/robots.txt`), not per-subpath. A file shipped at `docs/robots.txt` builds to `https://aayushgour.github.io/clipnest/robots.txt`, which is **not** the authoritative location any crawler actually checks — crawlers check the `aayushgour.github.io` origin root, which this project doesn't control (that's a separate user-site repo, `aayushgour.github.io`, which may not exist). **In practice this is a non-issue right now**: the *absence* of any robots.txt at that origin root is functionally identical to the "allow everything" policy this project wants — nothing is being blocked today either way. Shipping `docs/robots.txt` is still correct and required: (a) it documents intent, (b) it becomes fully authoritative the moment a custom domain (`clipnest.app`) is CNAME'd per decision #3, since the domain's root and the Pages publish root become the same thing. Ship it now; note the caveat in the task so devops doesn't think it's inert-forever.

---

## 1. Repo metadata (single highest-value, lowest-effort lever — R1/R4)

GitHub's default repo search scope is **name + description + topics only**, never README body. This is the first thing to fix.

### Description (exact string, replaces "Clipboard manager for MacOS")
```
Free, open-source clipboard manager for macOS (SwiftUI). History, search, pins, and snippets with keyword expansion in any app — plus optional on-device OCR.
```
~160 chars, comfortably under every unofficial length ceiling found in research. Leads with "clipboard manager" + "macOS" (the two terms people actually type), states **free/open-source** (real differentiator vs. Deck [no license], ClipBook [source-available, not OSS], Paste/Pastebot/Raycast [closed, paid]), names the two genuinely-differentiating features (snippet keyword expansion, OCR) without leading with "no telemetry"/"100% local" — those are commodity claims in 2026 (every competitor makes them; R4 §4) and would waste scarce description characters on a non-differentiator.

### Topics (18 of the 20 max — 2 slots deliberately left free for a future differentiator, per R1)
In priority order:
1. `clipboard-manager` 2. `clipboard` 3. `clipboard-history` 4. `pasteboard` 5. `macos` 6. `macos-app` 7. `menu-bar-app` 8. `swift` 9. `swiftui` 10. `text-expander` 11. `snippet-manager` 12. `open-source` 13. `native-app` 14. `privacy-first` 15. `productivity` 16. `ocr` 17. `nspasteboard` 18. `developer-tools`

Rationale for the less-obvious ones: `pasteboard`/`nspasteboard` are Apple's own API terms — least-crowded topic pages found (79 and near-zero repos respectively) and technically accurate, not SEO tricks. `text-expander`/`snippet-manager` target R4's verified white-space #2 (system-wide keyword expansion bundled in a clipboard manager, not a separate app). Dropped from R1/R4's longer candidate lists as redundant/lower-value: `macos-menubar-app` (overlaps `menu-bar-app`), `menubar-app` (near-duplicate spelling, lower value than a genuinely new keyword), `swift-package` (misdescribes the *app* repo — would be accurate on a hypothetical separate SPI-only repo, not here).

### Other exact settings
- **Homepage field:** leave blank until the Pages site is live (T78), then set to `https://aayushgour.github.io/clipnest/`. Don't set a placeholder before the site exists.
- **Social preview image:** upload a custom 1280×640 PNG, under 1 MB (GitHub's own spec). Ship a branded placeholder now (derived from `assets/clipnest-icons/clipnest-color.svg` — the master, per project convention: icon treatments derive from its own paths, never a redrawn generic clipboard icon), swap for a real UI screenshot once the user's demo-video stills land. **Distinct asset from the site's OG image** (different aspect ratio: 1280×640 vs. 1200×630) — GitHub's social preview and the site's `og:image` are two separate uploads, both need placeholders now.
- **Wiki:** disable it (currently enabled + empty — reads as abandoned/unfinished to a human or agent evaluator; zero-risk cleanup).
- **DeepWiki:** `curl`/fetch `https://deepwiki.com/AayushGour/clipnest` once to trigger on-demand indexing (confirmed still un-indexed as of this session — see §0), then re-check via `mcp__deepwiki__read_wiki_contents` to confirm it now returns content instead of "not found."
- **CITATION.cff / FUNDING.yml:** explicitly **not doing** (see §7).

---

## 2. README rewrite (senior-dev, judgment-heavy — not mechanical)

Fix the stale/false hook and reposition per R4 §7's verified differentiators, in this order of emphasis:
1. **Accessibility permission survives every app update** (verified real pain, zero competitor messaging on it — R4's single cleanest white-space claim). This should be visible in the top-of-README pitch, not buried in the "Release/Signing" section where it lives today only as a technical aside.
2. **Free, open-source, native SwiftUI** — not "no telemetry"/"100% local" as the lead (commodity in 2026 per R4 §4); state it, don't headline it.
3. **Snippets with system-wide keyword expansion** — "replaces your text expander too" framing (R4 §7).
4. Reposition against **macOS 26 Tahoe's built-in history** honestly instead of ignoring it.

**Exact corrected hook, verified against R4 §0 and the app's own real shipped features — use this verbatim as the new "Why Clipnest?" opening, and reuse the same framing on the site's Home hero (§5) so the two stay consistent:**
> macOS 26 Tahoe added a basic clipboard history to Spotlight (⌘4) — but it's opt-in, caps out at 7 days, and can't organize, pin, or expand anything. Clipnest is a free, open-source, native menu-bar app that picks up where that leaves off: history you control, instant search, pinned favorites, and reusable snippets that expand by keyword in any app.

Keep the existing "Signing, honestly" section's framing verbatim (decision #1 — this transparency is a trust asset, don't soften or bury it). Add one clear link near the top: "Full docs & site → aayushgour.github.io/clipnest" once the site exists (T78) — this is a genuine dofollow backlink (verified directly by R3: README's `<article class="markdown-body">` external links carry no `rel` attribute at all on this exact repo).

---

## 3. Site architecture & deploy

**Deploy method: classic "Deploy from a branch" → `main` / `/docs`.** Matches GitHub's own stated decision rule (no custom build process needed; Jekyll + the already-allowlisted plugins `jekyll-sitemap`/`jekyll-seo-tag` cover everything) — zero workflow YAML to maintain. Revisit GitHub Actions only if a non-Jekyll generator is ever needed.

**URL structure (decision #3 — no custom domain yet, structured for one later):**
- `url: "https://aayushgour.github.io"`, `baseurl: "/clipnest"` in `_config.yml` → site lives at `https://aayushgour.github.io/clipnest/`.
- **Non-negotiable for every page/include/JSON-LD block:** use Jekyll's `relative_url` / `absolute_url` Liquid filters for every internal link, canonical tag, and JSON-LD URL — never hand-write a literal `/clipnest/...` or full `https://aayushgour.github.io/clipnest/...` path. This is what makes the custom-domain migration (decision #3) a one-line `_config.yml` change (`url`/`baseurl` only) instead of a site-wide find-replace. Reviewer must check this explicitly (§ acceptance criteria below).
- `CNAME` file: not created now (no custom domain yet); GitHub auto-writes one if/when a custom domain is set in Settings → Pages on a branch-deploy site — no action needed today.

### `/docs` coexistence decision (the repo's existing dev docs vs. the new public site)

`/docs` already holds `API.md` (712 lines, Swift API reference), `architecture.md` (563 lines), `features.md` (1283 lines, **developer** file:line implementation guide — confirmed by reading it directly, this is NOT a user-facing feature list despite the filename), `competitive-analysis.md` (281 lines), `usage.md` (245 lines, genuinely user-facing), and `review/` (internal QA reports). Because GitHub Pages' bundled `jekyll-optional-front-matter` plugin is **always on and cannot be disabled**, pointing Pages at `/docs` would by default auto-render **every** `.md` file there as a themed HTML page — including the dev-only ones — unless explicitly excluded.

**Decision — `_config.yml` `exclude:` list (these stay plain repo markdown, browsable on GitHub, but are never built into the Pages site, never in the sitemap, never indexed as site pages):**
```yaml
exclude:
  - API.md
  - architecture.md
  - features.md
  - competitive-analysis.md
  - review/
```
**`competitive-analysis.md` is deliberately excluded and NOT published, full stop.** It reads as an internal strategy memo, not user-facing content: "Tier 0/1/2/3 roadmap," "the wedge," "unwinnable in this window," explicit internal prioritization language, and — critically — it's already been caught stale on a real fact (OCR framed as unshipped, see §0). Publishing a company's internal competitive roadmap to the public, un-fact-checked against the live app, fails the brief's "everything published must be true" bar and reads unprofessional. Instead: a **new**, separate, fact-checked public comparison page is authored fresh (§5, Compare page) — same underlying research, filtered to only verified, non-strategy claims, written for a reader deciding between tools, not for a competitor reading a roadmap.

**Net-new site content lives in a new `docs/pages/` folder** (keeps new marketing content visually/organizationally separate from existing dev docs, no renames needed): `docs/pages/index.md`, `features.md`, `download.md`, `compare.md`, `privacy.md`, `faq.md`, each with a `permalink:` front-matter key controlling its final URL independent of file location.

**`docs/usage.md` is reused directly** (it's already accurate, macOS-only, user-facing) — add Jekyll front matter (`layout`, `title`, `permalink: /usage/`) to its existing top, no content fork. **One real staleness bug to fix while doing this:** its "First launch — a Gatekeeper heads-up" section (lines 37-47) still describes the *old* xattr/right-click workaround, predating the current, more accurate curl-install + self-signed-cert + checksum-verify story that README's "Signing, honestly" section now tells correctly. Reconcile `usage.md`'s Gatekeeper section to match README's current framing before publishing — don't ship the stale version.

**Theme:** `minima` (GitHub Pages' default-supported theme, in the bundled gem allowlist) with a custom `_layouts/default.html` override (same relative path as the theme's own layout — Jekyll's standard override mechanism) carrying the JSON-LD + OG/Twitter includes. Keeps scope sane for M size — no full custom design system build; ux-designer does a lightweight visual/brand pass on top of minima's structure, not a from-scratch build.

**Skip `jekyll-feed`** (bundled/allowlisted, R3 mentioned it as part of a standard trio) — there is no blog/`_posts` collection (decision: no blog at all, an empty/thin blog is worse for SEO than none, per R3), so an Atom feed would be empty and pointless. Use only `jekyll-sitemap` + `jekyll-seo-tag`.

### File layout
```
docs/
  _config.yml
  Gemfile                      # pins jekyll + github-pages gem, local-preview parity
  _layouts/default.html        # minima override + JSON-LD/OG includes in <head>
  _includes/seo-jsonld.html    # WebSite (site-wide) + SoftwareApplication (home only)
  _includes/og-tags.html       # OG + Twitter meta
  assets/
    og-image.png               # 1200x630 placeholder now, real screenshot later — filename stays stable
    screenshot-picker.png       # placeholder now, same filename swapped later
  pages/
    index.md                   # Home        → permalink: /
    features.md                # → permalink: /features/
    download.md                 # → permalink: /download/
    compare.md                  # → permalink: /compare/
    privacy.md                  # → permalink: /privacy/
    faq.md                       # → permalink: /faq/
  usage.md                      # existing file, front matter added → permalink: /usage/
  robots.txt
  # sitemap.xml is generated by jekyll-sitemap — never hand-written
  # API.md / architecture.md / features.md / competitive-analysis.md / review/ — existing, excluded from build (untouched otherwise)
```

---

## 4. Page plan (macOS-only scope; every page's copy must be checkable against the live code/README)

| Page | URL | Target query intent | Title tag | Meta description | Content summary |
|---|---|---|---|---|---|
| **Home** | `/` | Brand ("clipnest"), head-term ("clipboard manager for mac"), white-space long-tail ("clipboard manager that doesn't lose accessibility permission after update") | `Clipnest — Free, Open-Source Clipboard Manager for Mac` | `Clipnest is a free, open-source, native macOS clipboard manager: full history, instant search, pins, and snippets that expand by keyword in any app — plus permissions that survive updates.` | Hero = the corrected Tahoe-aware hook (§2, verbatim, same copy as README for one voice); feature highlights (history/search/pins/snippets/OCR, in that priority order — OCR mentioned, not led with); Accessibility-survives-updates callout; screenshot placeholder (stable filename, see above); download CTA; links to Features/Compare/FAQ/Privacy; `SoftwareApplication` + `WebSite` JSON-LD. |
| **Features** | `/features/` | "mac clipboard manager with snippets", "clipboard manager global hotkey mac" | `Features — Clipnest Clipboard Manager` | `Full clipboard history, instant search, pinning, reusable snippets with keyword expansion, optional on-device OCR, and a global hotkey — all native to macOS.` | Sourced from README's own Features list + Settings section — NOT `docs/features.md` (that file is a developer file:line implementation guide, wrong register entirely for this page — a real mismatch in R3's original page plan, corrected here). |
| **Download** | `/download/` | "download clipnest", "clipnest mac download", "free clipboard manager mac download" | `Download Clipnest for macOS (Free)` | `Download Clipnest free for macOS 14 Sonoma and later. Open source, no account required — one command to install.` | The curl one-line install, link to latest GitHub Release, requirements (macOS 14+), and the "Signing, honestly" trust framing reused verbatim from README (decision #1) — this is the page most likely to be the first thing a skeptical visitor reads before running a curl-pipe-bash command, so the transparency has to be right here, not just in README. |
| **Usage** | `/usage/` | "how to use clipnest", "mac clipboard manager hotkey shortcuts" | `Getting Started with Clipnest — Usage Guide` | `Learn Clipnest's hotkeys, search, pinning, and snippet expansion — get productive with your Mac clipboard manager in minutes.` | Reuse of `docs/usage.md`, Gatekeeper section reconciled with README's current story (see §3). |
| **Compare** | `/compare/` | "maccy alternative", "clipnest vs maccy", "clipnest vs deck", "macOS Tahoe clipboard history vs [third-party manager]" | `Clipnest vs Maccy, Deck & macOS Tahoe — Comparison` | `How Clipnest compares to Maccy, Deck, and macOS Tahoe's built-in clipboard history: features, price, privacy, and what's actually different.` | **Freshly authored**, fact-checked against the live app and each competitor's current site/repo at build time (not lifted from `docs/competitive-analysis.md` — see §3's exclusion decision). Covers: Maccy (free OSS incumbent — the actual "maccy alternative" query volume), Deck (closest architectural twin — native SwiftUI, but ships no license, unlike Clipnest's real MIT), and macOS 26 Tahoe's built-in history (the new query cluster, low competition today). One honest comparison table + prose, no aggregate scoring, no fabricated superiority claims. |
| **Privacy** | `/privacy/` | "is clipnest safe", "clipboard manager privacy mac", "clipnest telemetry" | `Privacy — Clipnest is 100% Local, No Cloud, No Telemetry` | `Clipnest never sends your clipboard data anywhere. No servers, no sync, no telemetry, no account — see exactly what stays on your Mac and the OCR trade-off, honestly.` | Adapted from README's "Privacy first" section verbatim (already accurate and detailed) — this is the one page where leading with "100% local/no telemetry" is correct, because the page's entire query intent *is* that topic (unlike the homepage hero, where it would waste the lead on a commodity claim). Include the OCR trade-off paragraph as-is (README already frames it honestly). |
| **FAQ** | `/faq/` | "does clipnest support images", "is clipnest free", "clipnest vs Apple clipboard", "does clipnest lose accessibility permission after update" | `Frequently Asked Questions — Clipnest` | `Answers to common questions about Clipnest: pricing, privacy, supported macOS versions, snippets, OCR, permissions, and how it compares to other clipboard managers.` | Question-shaped H2s, each answer self-contained and answer-first (R2's one well-evidenced structural AEO tactic — passage-based retrieval across every engine surveyed). Must include: pricing/OSS, does it work offline, OCR trade-off, "does Clipnest lose Accessibility permission after an update" (the verified white-space claim, given a real FAQ answer, not just a README aside), and "how is Clipnest different from Maccy/Deck" linking to `/compare/`. Plain prose — **no `FAQPage` schema wrapper** (see §7). |

Deliberately **not** building: a standalone blog, a dedicated "text expander" landing page (folded into Home/Features/FAQ instead — full landing page is a stretch-goal, not needed for M scope).

---

## 5. JSON-LD design

**Ship:** `SoftwareApplication` (home page only) + `WebSite` (site-wide, in the shared layout). **Skip:** `FAQPage`, `HowTo`, `aggregateRating`/`review`, `BreadcrumbList`, `WebSite.SearchAction` — see §7 for why (these are user decisions already made, restated here with the technical reasoning).

`Organization` is deliberately **not** used anywhere — Clipnest is a solo-dev project with no legal entity; fabricating one is exactly the kind of misleading markup Google's structured-data policy warns against. Use `Person` (Aayush Gour) consistently as both `author` and `WebSite.publisher`.

**`SoftwareApplication` (home page):**
```json
{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "Clipnest",
  "alternateName": "Clipnest Clipboard Manager for Mac",
  "description": "Clipnest is a free, open-source, native macOS clipboard manager. It remembers everything you copy — text, links, images, and files — with instant search, pinning, and reusable snippets that expand by keyword in any app. Optional on-device OCR, no account, no cloud, no telemetry.",
  "applicationCategory": "UtilitiesApplication",
  "applicationSubCategory": "Clipboard Manager",
  "operatingSystem": "macOS",
  "softwareVersion": "REPLACE_WITH_LATEST_RELEASE_TAG",
  "softwareRequirements": "macOS 14 Sonoma or later",
  "downloadUrl": "https://github.com/AayushGour/clipnest/releases/latest",
  "installUrl": "https://github.com/AayushGour/clipnest/releases/latest",
  "fileSize": "REPLACE_WITH_DMG_SIZE_EG_8MB",
  "datePublished": "REPLACE_WITH_LATEST_RELEASE_DATE_ISO8601",
  "releaseNotes": "https://github.com/AayushGour/clipnest/releases",
  "featureList": "Full clipboard history (text, rich text, images, files, links); instant search; pinning; reusable snippets with keyword expansion in any app; global hotkey; optional on-device OCR (off by default); 100% local storage",
  "screenshot": {
    "@type": "ImageObject",
    "url": "{{ '/assets/screenshot-picker.png' | absolute_url }}",
    "caption": "Clipnest's clipboard history picker"
  },
  "softwareHelp": { "@type": "CreativeWork", "url": "{{ '/usage/' | absolute_url }}" },
  "license": "https://opensource.org/licenses/MIT",
  "isAccessibleForFree": true,
  "offers": { "@type": "Offer", "price": "0", "priceCurrency": "USD" },
  "author": { "@type": "Person", "name": "Aayush Gour", "url": "https://github.com/AayushGour" },
  "sameAs": ["https://github.com/AayushGour/clipnest"]
}
```
Note: `codeRepository` is **not** a valid property on `SoftwareApplication` (verified directly against schema.org — it's `SoftwareSourceCode`-only); `sameAs` is the correct property for the GitHub URL, used above. `softwareVersion`/`fileSize`/`datePublished` placeholders must be filled from the actual latest GitHub Release at build/deploy time — going stale here is itself a structured-data quality problem (Google's own policy requires markup to reflect actual page content); a small Actions step querying the Releases API is a reasonable follow-up but not required for initial ship (manual fill-in at deploy time is acceptable for M scope).

**`WebSite` (every page, via the shared layout):**
```json
{
  "@context": "https://schema.org",
  "@type": "WebSite",
  "name": "Clipnest",
  "url": "{{ '/' | absolute_url }}",
  "publisher": { "@type": "Person", "name": "Aayush Gour", "url": "https://github.com/AayushGour" }
}
```

**OG + Twitter tags (every page, via `_includes/og-tags.html`):** `og:type`, `og:title`, `og:description`, `og:url` (all via `absolute_url`), `og:image` (1200×630, placeholder now), `og:image:width`/`height`, `og:site_name`, `og:locale`; `twitter:card=summary_large_image` + mirrored title/description/image (cheap insurance — X's crawler falls back to OG tags regardless, and Reddit/Slack/Discord/HN link previews all read OG directly, which is exactly the audience that drives early stars).

---

## 6. robots.txt (decision #2 — allow everything, including AI training crawlers)

```
User-agent: *
Allow: /

Sitemap: https://aayushgour.github.io/clipnest/sitemap.xml
```
Deliberately the blanket wildcard form, not an enumerated per-bot list. A wildcard `Allow: /` already covers every named crawler (GPTBot, ClaudeBot, CCBot, PerplexityBot, Google-Extended, OAI-SearchBot, ChatGPT-User, Claude-User, Claude-SearchBot, Bytespider, Amazonbot, and any future one) with zero future maintenance — an enumerated list would need updating every time a new AI crawler UA string appears, working against "maximum inclusion." See §0 for the origin-root caveat (currently inert in practice, becomes fully authoritative once/if a custom domain is added).

---

## 7. Explicit "NOT doing" (and why)

- **`llms.txt`** — user decision, overriding R2's softer "ship it anyway, ~20 min, no harm" suggestion. Two independent measurements (Ahrefs 137k-domain study, Evil Martians' own 2-month server-log study) show near-zero AI-assistant read rate; Google's own John Mueller called it "comparable to the keywords meta tag." Not shipping it at all, per user decision.
- **`FAQPage` / `HowTo` JSON-LD** — Google deprecated both rich results (2023 restriction, full removal by mid-2026). The FAQ page's plain, question-shaped prose (§4) captures the same passage-extraction value the schema would have claimed, without the redundant markup.
- **`aggregateRating` / `review`** — Google's own structured-data policy explicitly bars a self-reviewed entity from using this; violating it risks a **manual action** (loss of all rich results, not just this one). No genuine third-party review corpus exists yet for Clipnest. Never fabricate one.
- **`WebSite.SearchAction` (sitelinks searchbox)** — Google removed the feature entirely, November 2024. Dead code if shipped.
- **`BreadcrumbList` schema** — no evidence of any LLM-retrieval benefit found in research; the site is flat (7 pages), so the classic-SERP payoff is minimal too. Skip.
- **Official `homebrew/cask`** — permanently blocked without a paid Apple Developer account: even at high star counts, Homebrew's own `brew audit --new --cask` runs a real Gatekeeper/`spctl` assessment against the extracted binary, which a self-signed (non-Developer-ID) cert cannot pass. Per decision #1, out of scope entirely for now.
- **Personal Homebrew tap** (`AayushGour/homebrew-clipnest`) — technically eligible today (no review gate), but per decision #1 it's low value (`brew search` doesn't index third-party taps — convenience for people who already know about Clipnest, not a discovery channel) and its own cask-install path may itself trigger the Gatekeeper "unidentified developer" dialog (untested), undercutting the pitch. Left as an optional, unscheduled stretch item — not tasked in this plan.
- **A blog** — no `_posts` collection, no `jekyll-feed`. An empty/thin blog is a worse signal than no blog at all (R3).
- **`AGENTS.md`** — genuinely good practice for a dev-facing OSS repo, but it is explicitly **not an AEO tactic** (R2: it's read by coding agents already working in the repo, not by answer engines fielding "what's a good clipboard manager" queries) — out of scope for *this* initiative. Worth doing as a separate, unrelated task later.
- **`awesome-swift` / `awesome-privacy` submissions** — both have hard, currently-unmet gates (`awesome-swift`: 15-star minimum; `awesome-privacy`: first release must be ~4 months old, currently ~3.5 weeks). Not tasked now; log as a month-3/4 follow-up for whoever owns distribution next (PM).
- **Wikipedia article** — notability bar far too high for a 0-star project; likely speedy-deleted.
- **Content negotiation / hidden `<link rel="alternate" type="text/markdown">` hints** — Evil Martians tested this directly and measured zero attributable fetches across 268k requests. Skip.
- **Paid AEO-tracking SaaS** (Profound/Peec AI/Otterly/AthenaHQ) — nothing to measure yet at 0 stars/near-zero traffic.
- **Raw server-log bot-traffic grepping** (R2 §9's other measurement suggestion) — **not feasible as stated**: GitHub Pages does not expose raw access logs to the site owner (unlike a Cloudflare/Vercel/Netlify deploy). Substitute: Google Search Console + Bing Webmaster Tools (already tasked, T78) give query/referrer visibility instead. Adding a third-party analytics/CDN layer for real log access is a separate, bigger decision (it would sit oddly next to the app's own "no telemetry" positioning, even though a marketing site having analytics is a different and more defensible thing) — flagged for a future call, not decided or tasked here.
- **Linux anything** — explicit scope exclusion for this whole initiative. No Linux content in site copy, metadata, robots.txt, or JSON-LD, anywhere, ever, per the brief.
- **Custom domain purchase / notarization ($99 Developer account)** — both already decided against for now (user's standing decisions), both structurally prepared for later (baseurl/URL design in §3 makes a domain migration a one-line config change; the signing story is documented honestly rather than hidden).

---

## Acceptance criteria that apply to every task touching the site (reviewer checks all of these on every task, not just the ones that mention it explicitly)
1. No literal `/clipnest/...` or hardcoded `https://aayushgour.github.io/...` path anywhere — always `relative_url`/`absolute_url` Liquid filters.
2. No Linux content, no cross-platform claims, no Wayland/GTK/anything referencing the Linux port, anywhere.
3. Every factual claim in new copy is checkable against README.md / the actual source / a live-fetched competitor page at the time of writing — not copied from `docs/competitive-analysis.md`'s numbers without re-verification.
4. No `aggregateRating`, no `FAQPage`/`HowTo` JSON-LD, no `WebSite.SearchAction`, no fabricated `Organization`.
5. Placeholder media (OG image, screenshot, GitHub social preview) ships now at a **stable filename/path** so a later real-media swap requires zero link/reference changes anywhere.
