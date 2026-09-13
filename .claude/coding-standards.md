# Coding standards — Clipnest

Owner: architect (seed) · senior-dev refines. Grep this before building; match it.

## Non-negotiables (every project, every agent, regardless of stack)

- **A cross-platform seam MUST NOT have a silent default.** An injected closure or protocol witness that one platform fills and another silently does not is invisible: the call site compiles, the feature does nothing, and no test fails. Declare it as a required initializer parameter (or a non-optional `let` set at construction) so a missing wiring is a BUILD ERROR, not a dead feature.
  **Evidence — this exact bug shipped three times in one day on the Linux port:**
  `PickerViewModel.presentSnippetEditor` defaulted to `{ _ in }`; macOS injected it, Linux never did, and snippet creation silently did nothing for the ENTIRE port — `saveHighlightedAsSnippet()` ran, called the closure, and returned. `PickerViewModel.openSettings` defaulted to `{}` and was likewise never set on Linux, so binding `Ctrl+,` would have dismissed the picker and done nothing. Both were found by accident, not by a test. `SettingsWindow.reinstallToggleHotkeyFloor` and `requestUInputGrant` were deliberately declared WITHOUT defaults for this reason and are the pattern to copy.
  When you genuinely need a no-op fallback (a headless test, say), make it explicit at the call site — `presentSnippetEditor: { _ in }` written out — never a default the caller can forget.

- **Re-entrancy: a GTK signal handler that changes window state must not re-enter itself.** Hiding a window makes it inactive, which fires `notify::is-active`, whose handler may hide it again. The same shape recurred FIVE times in one day (dismissal, context menu, snippet editor, and two grab handoffs) — twice reaching 156% and 200%+ sustained CPU before being caught. Guard with an explicit re-entrancy flag, and defer window/grab handoffs to the next GLib idle iteration (`g_idle_add_full`) rather than performing them synchronously inside the signal.
- **DRY** — no copy-pasted logic. Extract to a shared function/module the *second* a real duplicate appears (not preemptively).
- **No magic strings/numbers** — every literal used more than once, or that carries meaning (status codes, keys, routes, error messages, thresholds), lives in one `constants` module. Nothing else hardcodes it inline.
- **Config in one place** — all env vars read through a single config module (e.g. `config.py` / `config.ts`); rest of the codebase imports from it. Never scatter raw `process.env.*` / `os.environ.*` calls through business logic.
- **Consistency** — one way to do a thing per project (naming, error handling, file layout). New code matches existing patterns; don't introduce a second convention.
- **Reusability + separation of concerns** — one module = one responsibility. Business logic separate from I/O/framework glue. Prefer composition over duplication.
- **Lint clean, enforced not optional** — formatter + linter run and pass before handoff (pre-commit or CI gate, not manual discipline). Zero new lint errors on touched files.

## Stack
- **Language:** Swift 6 (strict concurrency mode on for `ClipnestCore`; `ClipnestApp` may relax to `@MainActor`-default where SwiftUI/AppKit requires it).
- **UI framework:** SwiftUI, with AppKit interop where SwiftUI has no coverage (`NSPanel` for the picker, `NSStatusItem`/`MenuBarExtra`, `CGEvent` synthesis, `NSPasteboard`).
- **Minimum OS:** macOS 14.0 (Sonoma) — set via `platforms: [.macOS(.v14)]` in `Package.swift` and `MACOSX_DEPLOYMENT_TARGET` / `options.deploymentTarget.macOS: "14.0"` in `project.yml`. Never lower this without an architect decision logged in `project-context.md` (it's the binding constraint for SwiftData + `SMAppService`).
- **Persistence:** `ClipItem`/`Snippet`/`ItemKind` are `Sendable` domain **value types** (structs/enum) — the models surfaced to all of `ClipnestCore` and `ClipnestApp`; they are NOT `@Model` types. SwiftData is the *production* persistence for their metadata (D1 stands) but is **confined behind the `ClipStore`/`SnippetStore` protocols**: the concrete `SwiftDataClipStore`/`SwiftDataSnippetStore` own a *private* `@Model` entity and map to/from the domain struct — a SwiftData type never crosses the Store boundary. **Interim, until full Xcode.app is installed (see decision D6):** the concrete store is the pure in-memory `InMemoryClipStore`/`InMemorySnippetStore`; **no `@Model` exists anywhere in the tree yet** — the `@Model` macro plugin (`SwiftDataMacros`) ships only with Xcode.app, not Command Line Tools, and a single `@Model` use would break the whole one-unit `ClipnestCore` build (and thus all of `swift test`). Large payloads never go in the metadata store — they go through `BlobStore` on disk, content-addressed by hash (`BlobStore` is non-SwiftData disk storage and works today).
- **Distribution:** non-sandboxed, Developer ID signed + notarized `.dmg`. No App Sandbox entitlement.

## Formatter / linter
- **Tool:** `swift-format` (Apple, ships with the Swift 6 toolchain — no extra install, keeps the dependency count at the one approved package).
- **Lint (check only, CI/pre-handoff gate):**
  `swift format lint --recursive --strict Sources Tests` (run from repo root for `ClipnestCore`) and `swift format lint --recursive --strict ClipnestApp/Sources` (for the app target).
- **Format (auto-fix, run before committing):**
  `swift format format --in-place --recursive Sources Tests` and the equivalent for `ClipnestApp/Sources`.
- Zero warnings/errors from `lint --strict` on any touched file before a task moves to `review`.

## Test framework + how to run
- **Framework:** Swift Testing (`import Testing`, `@Test`, `#expect`/`#require`) for all `ClipnestCoreTests`. Do not mix in XCTest unless a specific AppKit/async interop issue forces it — if that happens, log it as a new decision in `project-context.md` before doing it.
- **Run (Core, CLI-only, no Xcode needed):** `swift test` from the repo root (runs the `ClipnestCoreTests` target defined in `Package.swift`).
- **Run (App smoke tests, if any):** `xcodebuild test -project ClipnestApp/ClipnestApp.xcodeproj -scheme ClipnestApp -destination 'platform=macOS'` after `xcodegen generate`.
- UI is kept thin by design (spec: "UI kept thin; light smoke tests only") — the bulk of logic and nearly all unit tests live in `ClipnestCore` and run via `swift test` with zero GUI launch.
- No feature ships without unit tests for the `ClipnestCore` logic it depends on. Mock side effects (event synthesis, filesystem where practical) so tests are deterministic and CI-safe — never synthesize real key events or touch `NSPasteboard` from a test. Store tests run against `InMemoryClipStore`/`InMemorySnippetStore` (the canonical in-memory store — see Persistence + D6), not a real on-disk DB.

## Naming conventions
- Swift API Design Guidelines throughout: `UpperCamelCase` types/protocols, `lowerCamelCase` members/functions/variables.
- One primary type per file; file name matches the type (`ClipStore.swift` defines `protocol ClipStore`; its concrete implementation lives in its own file named for its actual backing — `InMemoryClipStore.swift` today, `SwiftDataClipStore.swift` once SwiftData persistence lands per D6/T40 — never merge two unrelated types into one file).
- Protocols named as capabilities/roles (`ClipStore`, `EventSynthesizing`), not suffixed `...Protocol`/`...Impl`; concrete implementations get a **descriptive prefix that names the real backing** (`InMemoryClipStore`, `SwiftDataClipStore`) instead of a generic `...Impl` suffix — and never a prefix that lies about the backing (do not name an in-memory store `SwiftData...`).
- Test files: `<TypeUnderTest>Tests.swift`, one `@Suite` per type, `@Test` functions named as `should_...` / behavior sentences (e.g. `@Test func dedupCollapsesConsecutiveIdenticalCopies()`).

## Error-handling pattern
- **Typed `throws` with per-module `Error` enums.** Every module that can fail defines its own `enum <Module>Error: Error, Equatable` (e.g. `ClipStoreError`, `BlobStoreError`, `PasteError`) with specific cases (`.notFound`, `.ioFailure(underlying: String)`, `.accessibilityNotGranted`, …). Callers `do/catch` or propagate with `throws`; do not swallow errors silently.
- No `Result<T, Error>` wrapping for synchronous calls — use `throws`/`try`. `Result` is acceptable only at an async completion-handler boundary if one is unavoidable (prefer `async throws` everywhere instead).
- No force-unwraps (`!`), force-try (`try!`), or force-cast (`as!`) in `ClipnestCore` or `ClipnestApp` production code — only ever in test code where a precondition is guaranteed by the test setup. `swift-format`'s strict lint should flag these; treat any as a review blocker.
- Recoverable/expected failures (e.g. Accessibility not granted) are modeled as typed errors or explicit state the caller checks — never a crash. `Paster` in particular must degrade to "item on clipboard, no synthesized paste" rather than throw/crash when Accessibility is missing (see Privacy/Permissions below).

## Module / folder layout
Two modules, matching the spec: `ClipnestCore` is a plain SPM library (fully unit-testable, zero UI), `ClipnestApp` is an XcodeGen-generated `.app` target that depends on it.

```
mac-clipboard-manager/                     (repo root)
├── Package.swift                          # SPM package: ClipnestCore
├── Sources/ClipnestCore/
│   ├── Model/          (ClipItem, Snippet, ItemKind — Sendable value types)
│   ├── Clipboard/       (ClipboardMonitor, PasteboardReader, PrivacyFilter)
│   ├── Store/           (ClipStore protocol, InMemoryClipStore [SwiftDataClipStore added at T40], SnippetStore, InMemorySnippetStore, BlobStore)
│   ├── Search/          (SearchQuery, SearchFilter)
│   └── Paste/           (FrontmostAppTracker, EventSynthesizing, Paster)
├── Tests/ClipnestCoreTests/   (one *Tests.swift per unit above)
├── ClipnestApp/                            # XcodeGen project (own dir; .xcodeproj is generated + gitignored)
│   ├── project.yml
│   ├── Sources/
│   │   ├── App/          (@main entry, MenuBarExtra, AppDelegate)
│   │   ├── UI/Picker/    (PickerPanel, PickerView, ItemRow, TabSwitcher, TypeFilterChips)
│   │   ├── UI/Settings/  (SettingsView, HotkeySettingsView, ExcludedAppsView)
│   │   └── System/       (HotkeyManager, LaunchAtLogin, PermissionsManager)
│   └── Resources/        (Assets.xcassets, ClipnestApp.entitlements, Info.plist)
└── scripts/               (build.sh, sign.sh, notarize.sh, package_dmg.sh)
```
Exact file-by-file breakdown and `project.yml`/`Package.swift` contents are in `docs/superpowers/plans/2026-08-06-clipnest-plan.md` (task T2). Don't invent a second layout — extend this one.

## Dependency policy
- **Exactly one third-party dependency, everywhere in the repo:** [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) (Sindre Sorhus, MIT), used only by `ClipnestApp` for global-hotkey registration + the SwiftUI recorder. `ClipnestCore` has **zero** third-party dependencies.
- Pin the exact resolved version in `Package.resolved` once added (task T27); don't float across major versions without a logged decision. Verify the license (MIT) and current release tag at implementation time — do not assume the version baked into an old plan is still current.
- Everything else is a system framework: `Foundation`, `SwiftUI`, `AppKit`, `SwiftData`, `CoreGraphics` (CGEvent + image downscaling for OCR), `ImageIO` (image header probing + bounded thumbnail decode — `CGImageSource*`; already in use in `ClipnestCore` since the OCR/paste work, this list simply never enumerated it), `Vision` (`VNRecognizeTextRequest`, on-device text recognition — see `ClipnestCore/OCR/`; on-device only, no model download and no network), `UniformTypeIdentifiers`, `ServiceManagement` (`SMAppService`). No networking libraries, no analytics/crash-reporting SDKs, no logging frameworks beyond `os.Logger`.
- Reviewer checks every new `import` against this list; anything not on it is a rejection, not a nit.

## Privacy / security musts (first-class for this app — clipboard content is inherently sensitive)
- **Local-only, always.** No `URLSession`, no sockets, no analytics/telemetry calls anywhere in the codebase. Reviewer greps for networking APIs on every review as part of the mandatory security pass (see `instructions.md` integrity rule 3 — this app's core function is "external I/O"-adjacent user input, so the security pass is **mandatory on every task that touches capture, storage, or settings**, not optional).
- **Honor pasteboard privacy markers.** `PasteboardReader`/`PrivacyFilter` must skip capture whenever the pasteboard carries `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType` — no exceptions, no setting can override this.
- **Auto-exclude password managers.** Ship a built-in bundle-ID exclude list (1Password, Bitwarden, LastPass, Dashlane, Keeper, etc. — verify current bundle IDs via web search at implementation time, don't guess) in addition to the pasteboard-marker check; users can extend it in Settings but never shrink the concealed/transient rule.
- **Never log clipboard content.** Logging (via `os.Logger`) may record metadata only — `ItemKind`, `byteSize`, a truncated/hashed identifier — never raw `previewText`/blob bytes.
- **Accessibility is optional, not required.** Reading the pasteboard and registering the hotkey need no special permission. Only the synthesized-⌘V paste step needs Accessibility (`AXIsProcessTrusted`); when not granted, `Paster` must still place content on the clipboard and let the app remain fully usable — never block or crash on missing permission.
- **No secrets in scripts.** Signing/notarization scripts (`scripts/sign.sh`, `scripts/notarize.sh`) must read credentials from a `notarytool` keychain profile (`xcrun notarytool store-credentials`) or environment variables set outside the repo — never a hardcoded Apple ID, app-specific password, or API key committed to the repo.

## Commit style
- Agents run `git add` on their own changed files only; **no agent runs `git commit` or `git push`** — the user authors commits (per spec's Implementation Workflow). Conventional, scoped messages if the user asks for a suggested message: `feat(core): ...`, `fix(app): ...`, `chore(build): ...`.

## Non-negotiable: never report an unconfirmed outcome as a confirmed one

**Absence of a failure signal is not presence of a success signal.** If an operation cannot be confirmed, it must report a distinct third state — never fold "no answer" into "success".

This codebase has produced three instances, each of which cost hours and each of which actively misdirected the person debugging it. A crash sends you to the right place; a false success sends you everywhere else, confidently.

- **`Paster` / `outcome=replaced` (2026-09-13).** Snippet expansion logged `matched=true`, `posted=true`, `outcome=replaced` while the clipboard had never changed — the Wayland compositor had silently dropped the write because a background handler has no input-event serial, and nothing returned an error. Every log line insisted it worked. Fixed by adding `SelectionReplaceResult.writeUnconfirmed`, so a posted-but-unconfirmed write is structurally *incapable* of reading as a confirmed one.
- **`AXError.success` (2026-09-12).** macOS AX reported success for both a stale read and a write that never landed. `.success` certifies that the call was *accepted*, never that it took *effect* or that it addressed the right control. Fixed by verifying writes (before/after range comparison) and gating reads behind a role allowlist — see D97.
- **`ClipnestControlService`'s missing fd overload (2026-09-13).** A D-Bus call fell through to the protocol's "unsupported" `nil` default and never sent a byte. Instrumentation showed `elapsedMs=0 gotReply=false` — a call that never reaches the wire cannot have a duration, yet a 596 ms figure from an unrelated polling ceiling was initially attributed to it.

**The corollary, learned the same way:** a test that cannot fail reads exactly like a test that passes. The Shell-extension ESM variant shipped unable to load for the entire life of the port because the test harness was `FROM ubuntu:22.04` — Shell 42, legacy variant only — so the environment structurally could not reach the broken path. Before trusting a new test, **run it against the unfixed code and watch it go red.** The ESM gate was only trusted after scoring 12/24 failures against the original and 24/24 against the fix.

**Wording is not a fix.** "killed (probably)" or "paste may have succeeded" is still a string a human skims past. The distinction has to live in the type, so the ambiguous case cannot be mistaken for the happy one at any call site. The sharpest statement of it: **a function that cannot express "I do not know" will always be forced to lie.** That is the argument for a third case over a hedged string.

**This is the same family as the no-silent-defaults rule at the top of this file, and the two were learned five months apart without anyone noticing they were the same thing.** A seam that silently defaults to `{ _ in }` and a call that silently reports `.replaced` both produce a feature that does nothing while every signal says it worked — one by never being wired, the other by never being checked. `presentSnippetEditor` cost the entire port; `outcome=replaced` cost a full session. When you add a rule here, look for the instance pointing the other way: this codebase has twice written a lesson about one direction and left the mirror case live.

**The smoke test that catches both directions, and costs seconds:** for anything you add or review, ask **"who reads this, and what would fail if nobody did?"** A `{ _ in }` default and a `.replaced` return both answer *nobody* and *nothing* — which is the whole defect. Apply it to a new field, a new enum case, a new D-Bus method, a new closure parameter, and to the mock or fake in the test: if the fake supplies a value the production path never sets, the suite agrees with a code path that does not exist.

**Known live instance in this repo, as of 2026-09-13:** the GNOME Shell extension implements `FocusAndSendKeyChord` and `GetFocusedApp`, both verified working against a real Mutter — and **no Swift code calls either**. `ShellHelperClient` has no wrapper, and `LinuxEventSynthesizerSelection.choose` never consults the extension for a paste backend. Meanwhile `debian/control` advertised the capabilities they provide to users (corrected in `84dfe24`). Implemented, tested, documented, shipped, unreachable — the mirror case, sitting in the tree while the rule above was being written. Tracked as `T-WLPASTE2`.

**Two diagnostics that fall out of it:**

- **The doc-comment tell.** Dead paths are routinely *described in the present tense by comments written in good faith*. `ShellHelperProtocol.swift` says `GetFocusedApp`'s fields are "called separately if a caller needs them" — no caller needs them. A sentence describing a future that never arrived is indistinguishable, in review, from one describing the present. This is why review cannot catch this class and a grep for readers can. The mechanism underneath: **agreeing sentences do not corroborate each other when they share an author and an assumption.** Each restatement makes the claim *more* credible while none of them is a check. This project's sharpest instance is not a comment at all — T-ATSPI1/D95: the AT-SPI `GetSelection` wire format was assumed wrong in the implementation **and encoded identically in its unit test**, so code and test agreed perfectly and the feature shipped at 0% success in the field with CI green. Two artifacts agreeing is evidence only when they were derived independently.
- **Severity escalates when the dead path is named in user-facing text.** An unused function is a lie to future maintainers. A dead path advertised in `debian/control`, a README, or release notes is a lie to **users** — `debian/control` told people the extension supplied app-aware privacy exclusions and verified paste targeting on Wayland, neither of which was reachable (corrected in `84dfe24`). **When you find a dead path, check the docs and package metadata before closing it out, not just the code.**

**A constraint on how to write these rules, not just which examples to pick:** argue from the case a reader can *see*. `presentSnippetEditor` works as the teaching example because the asymmetry sits two lines apart in one diff — macOS injects, Linux does not. Every other instance in this file needed a grep for readers to exist at all. A rule argued from the visible case gets followed; one argued from the invisible case gets nodded at.

