# Coding standards — Clipnest

Owner: architect (seed) · senior-dev refines. Grep this before building; match it.

## Non-negotiables (every project, every agent, regardless of stack)
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
- Everything else is a system framework: `Foundation`, `SwiftUI`, `AppKit`, `SwiftData`, `CoreGraphics` (CGEvent), `UniformTypeIdentifiers`, `ServiceManagement` (`SMAppService`). No networking libraries, no analytics/crash-reporting SDKs, no logging frameworks beyond `os.Logger`.
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
