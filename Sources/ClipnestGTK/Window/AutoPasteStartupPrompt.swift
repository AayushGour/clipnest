// AutoPasteStartupPrompt.swift
//
// Routed follow-up ("proactively prompt for the auto-paste permission at
// first run, the way macOS shows its Accessibility prompt — rather than
// only explaining the problem after the user has already hit it"): the
// Linux analogue of macOS's `AppEnvironment.requestAccessibilityOnceIfNeeded()`
// (`ClipnestApp/Sources/App/AppEnvironment.swift`) — a ONE-TIME, unsolicited
// nudge shown at startup, not just the passive Permissions-tab explanation
// `SettingsWindow+Permissions.swift` already ships (which only ever helps a
// user who already knows to go looking for it).
//
// GATING CONDITION (the design decision this task cared most about): shown
// only when the resolved paste backend is `.clipboardOnly` — never on the
// raw "uinput is missing" capability. An X11 session already gets
// auto-paste through XTEST with no uinput grant needed at all (see
// `LinuxEventSynthesizerSelection.choose`, `ClipnestPlatformLinux`), so
// prompting there would be pure nagging over a permission that changes
// nothing; the same gate will naturally suppress this prompt if a future
// paste backend (e.g. the GNOME Shell extension's `T-WLPASTE2`, not wired
// as of this task) starts resolving away from `.clipboardOnly` too, with no
// edit needed here. `ClipnestGTK` cannot import `ClipnestPlatformLinux` (see
// `Package.swift`'s dependency graph — the edge runs the other way), so this
// file never sees `SelectedEventSynthesizerKind` itself; it takes the exact
// same pre-erased `Bool` `PickerWindow.isAutoPasteAvailable` and
// `Paster.isAccessibilityGranted` already use (`LinuxAppEnvironment.init`'s
// `synthesizerResult.kind != .clipboardOnly`).
//
// NEVER-NAG PERSISTENCE: mirrors `SettingsStore.hasRequestedAccessibility`
// exactly — `SettingsStore.hasShownAutoPasteStartupPrompt` is set to `true`
// the INSTANT this decides to show the prompt (`showIfNeeded`, below),
// before the dialog is even built, not after some particular button is
// clicked. That is deliberate, not an oversight: a dialog the user closes
// via the titlebar X, or a process that dies mid-prompt, must still count
// as "shown" — otherwise this would nag on every single launch until the
// user happens to click one specific button, exactly the "re-prompted on
// every paste attempt made while untrusted" bug
// `requestAccessibilityOnceIfNeeded`'s own doc comment describes fixing on
// macOS. Persisted through the existing `SettingsStore`/`KeyValueStore`
// seam (a real JSON file on Linux, see `JSONFileKeyValueStore.swift`) — no
// second, bespoke dotfile.
//
// AFFIRMATIVE ACTION: "Grant Access…" drives the EXISTING `pkexec
// clipnest-grant-input` path directly (`GrantInputHelperClient`,
// `ClipnestLinuxAppKit` — injected here as the same `requestUInputGrant`
// closure type `SettingsWindow.requestUInputGrant` already uses), so a
// first-run user can grant without ever finding Settings > Permissions.
// The in-dialog flow (disable the two action buttons, show "Waiting for
// authentication…", then the real outcome) mirrors `SettingsWindow
// +Permissions.swift`'s `requestUInputGrantFromUI`/`applyGrantOutcome`
// almost verbatim — the closest existing precedent for wiring this exact
// `UInputGrantCompletion` type safely from a GTK signal handler.
//
// USE-AFTER-FREE GUARD: unlike the persistent, never-destroyed
// `SettingsWindow`/`PickerWindow`, this is a genuine one-shot `GtkWindow`
// that gets destroyed once the user is done with it — but `requestUInputGrant`
// (`pkexec`, waiting on a polkit authentication dialog) can outlive that by
// several seconds. `AutoPasteStartupPromptSession.isDismissed` is set the
// instant the window starts closing (either action button or the titlebar
// close button, via `close-request`) and checked before the async
// completion ever touches a widget pointer again — without this, closing
// the dialog mid-authentication and then having `pkexec` finally answer
// would call `gtk_label_set_text`/`gtk_widget_set_visible` on already-
// disposed widgets.
import CGtk4
import ClipnestViewModels

/// Pure gating/text logic — separated from GTK widget code so the one
/// decision that actually matters (WHEN this shows) is unit-tested
/// directly, mirroring `PermissionsTabPresentation`'s identical split
/// (`SettingsWindow+Permissions.swift`'s own doc comment explains the
/// precedent this follows).
public enum AutoPasteStartupPromptPresentation {
  /// See this file's top "GATING CONDITION" doc comment.
  public static func shouldShow(isAutoPasteAvailable: Bool, hasShownBefore: Bool) -> Bool {
    !isAutoPasteAvailable && !hasShownBefore
  }

  public static let title = "Set Up Auto-Paste?"

  /// What this unlocks, in user terms, and — just as important per this
  /// task's brief — an honest statement that Clipnest is fully usable
  /// without it (copy still works; the user pastes manually). No
  /// percentage/coverage claim: `ATSPITextAccessor`'s own doc comment
  /// estimates "roughly 30–50% of apps" for the Accessibility-only tier,
  /// but that is a developer-facing estimate, not a number precise enough
  /// to hand a user as a promise.
  public static let explanationText =
    "Clipnest can type a picked item straight into whatever app you're using, "
    + "and expand snippet keywords reliably in almost any app — but both need "
    + "permission to simulate a keystroke, which isn't set up yet. Without it, "
    + "picking an item just copies it to your clipboard (press Ctrl+V yourself), "
    + "and snippet expansion only works in apps that support Accessibility. "
    + "Clipnest works fine either way — this just makes both more convenient "
    + "and more reliable."

  /// Reused verbatim, not restated — see `PermissionsTabPresentation
  /// .securityExplanationText`'s own doc comment for the exact wording and
  /// why it matters. Duplicating a security-relevant claim in a second
  /// string risks the two silently drifting apart the next time either is
  /// edited; this file has exactly one copy, referenced from both places.
  public static let securityExplanationText = PermissionsTabPresentation.securityExplanationText

  /// Requirement 4 — "say plainly it needs a logout/login" — stated
  /// up front, before the user ever clicks Grant, not only after (the
  /// Permissions tab's own `reloginNoteText` only ever appears AFTER a
  /// grant already happened; this prompt's whole point is a user who has
  /// never seen either).
  public static let reloginText =
    "One thing to know up front: this only takes effect after you log out "
    + "and back in — group membership doesn't apply to your current login "
    + "session. If nothing changes right after granting, that's expected, "
    + "not a bug."

  public static let notNowButtonLabel = "Not Now"
  /// Reused verbatim — same button, same action, same wording as the
  /// Permissions tab's own Grant button.
  public static let grantButtonLabel = PermissionsTabPresentation.grantButtonLabel
  public static let closeButtonLabel = "Close"
  /// Reused verbatim — same in-flight wording as the Permissions tab shows
  /// for the identical `pkexec` wait.
  public static let grantInFlightStatusText = PermissionsTabPresentation.grantInFlightStatusText

  public static func succeededStatusText(message: String) -> String {
    "\(message) Log out and back in to start using it."
  }

  public static func failedStatusText(message: String) -> String {
    "Couldn't grant access: \(message) You can try again anytime from Settings → Permissions."
  }
}

/// Shows the one-time startup prompt when warranted. Called exactly once,
/// from `LinuxAppLifecycle.launch()`, right after the composition root
/// (`LinuxAppEnvironment`) exists — see that call site for why there rather
/// than inside `LinuxAppEnvironment.init` itself (init's job is
/// composition, not presenting UI; `LinuxAppLifecycle.launch()` is already
/// where the equivalent `.togglePicker`/`.expandSnippet` initial-command UI
/// is triggered).
public enum AutoPasteStartupPrompt {
  static let dialogWidth: Int32 = 440
  static let margin: Int32 = 20
  static let spacing: Int32 = 12
  static let wrapWidthChars: Int32 = 56

  /// - Parameters:
  ///   - isAutoPasteAvailable: the same pre-erased boolean
  ///     `PickerWindow.isAutoPasteAvailable`/`Paster.isAccessibilityGranted`
  ///     already receive (`synthesizerResult.kind != .clipboardOnly`) — see
  ///     this file's top "GATING CONDITION" doc comment for why the gate
  ///     lives on this derived value, not the raw uinput capability.
  ///   - settings: read/written directly (not via closures) — `SettingsStore`
  ///     already crosses into `ClipnestGTK` today (`SettingsWindow.settings`),
  ///     so this needs no new cross-module seam.
  ///   - requestUInputGrant: the exact same closure type/shape
  ///     `SettingsWindow.requestUInputGrant` takes — real callers pass
  ///     `GrantInputHelperClient.requestGrant(completion:)`
  ///     (`ClipnestLinuxAppKit`) directly, so "Grant Access…" here runs the
  ///     identical `pkexec clipnest-grant-input` helper the Permissions tab
  ///     uses, never a second privileged path.
  @MainActor
  public static func showIfNeeded(
    isAutoPasteAvailable: Bool,
    settings: SettingsStore,
    requestUInputGrant: @escaping (_ completion: @escaping UInputGrantCompletion) -> Void
  ) {
    guard
      AutoPasteStartupPromptPresentation.shouldShow(
        isAutoPasteAvailable: isAutoPasteAvailable,
        hasShownBefore: settings.hasShownAutoPasteStartupPrompt)
    else { return }
    // Set BEFORE presenting — see this file's top "NEVER-NAG PERSISTENCE"
    // doc comment for why the flag must not wait on a particular button.
    settings.hasShownAutoPasteStartupPrompt = true
    let session = AutoPasteStartupPromptSession(requestUInputGrant: requestUInputGrant)
    session.present()
  }
}

/// Owns the one-shot dialog's widgets and click handling. `@unchecked
/// Sendable` for the same documented reason `PickerWindow`/`SettingsWindow`/
/// `SnippetEditorWindow` already carry it: every access happens on the
/// single GTK thread (see `PickerWindow.swift`'s top "ACTOR ISOLATION" doc
/// comment) — this is what makes it sound to capture `self` inside the
/// `@Sendable UInputGrantCompletion` closure `handleGrantClicked()` hands to
/// `requestUInputGrant` below, mirroring `SettingsWindow
/// .requestUInputGrantFromUI`'s identical capture.
///
/// Kept alive after `AutoPasteStartupPrompt.showIfNeeded` returns purely by
/// GTK's own retained signal contexts (`connectSignals()`'s four
/// `gtkConnect(..., context: self, ...)` calls) — no other strong reference
/// survives past that call. Those same four connections are what release
/// `self` once the window is actually destroyed (each disposed widget's
/// `GClosureNotify` fires `releaseTrampolineContext` exactly once), so this
/// deallocates itself with no explicit teardown needed.
final class AutoPasteStartupPromptSession: @unchecked Sendable {
  private let window: OpaquePointer
  private let notNowButton: OpaquePointer
  private let grantButton: OpaquePointer
  private let closeButton: OpaquePointer
  private let statusLabel: OpaquePointer
  private let requestUInputGrant: (_ completion: @escaping UInputGrantCompletion) -> Void

  /// See this file's top "USE-AFTER-FREE GUARD" doc comment.
  private var isDismissed = false

  init(requestUInputGrant: @escaping (_ completion: @escaping UInputGrantCompletion) -> Void) {
    self.requestUInputGrant = requestUInputGrant

    window = gtk_window_new()
    gtk_window_set_title(window, AutoPasteStartupPromptPresentation.title)
    gtk_window_set_default_size(window, AutoPasteStartupPrompt.dialogWidth, -1)
    gtk_window_set_resizable(window, 0)
    // No transient parent: shown before the picker/settings windows are
    // ever made visible for the first time, so there is nothing sensible to
    // be transient-for yet. `gtk_window_set_modal` still works standalone —
    // it blocks input to any OTHER mapped top-level in this process's
    // default window group, and nothing else is mapped at this point in
    // startup.
    gtk_window_set_modal(window, 1)
    // Deliberately NOT `gtk_window_set_hide_on_close` — this is a genuine
    // one-shot dialog (unlike `SettingsWindow`/`SnippetEditorWindow`, reused
    // for the app's whole lifetime); the titlebar close button should
    // really destroy it, which is GTK4's default `close-request` handling
    // for an unhandled (propagated) request. `connectSignals()` still
    // listens for it below — not to change that behavior, only to record
    // `isDismissed` before it happens.

    let box: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, AutoPasteStartupPrompt.spacing)
    gtk_widget_set_margin_start(box, AutoPasteStartupPrompt.margin)
    gtk_widget_set_margin_end(box, AutoPasteStartupPrompt.margin)
    gtk_widget_set_margin_top(box, AutoPasteStartupPrompt.margin)
    gtk_widget_set_margin_bottom(box, AutoPasteStartupPrompt.margin)

    let titleLabel: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_xalign(titleLabel, 0)
    gtk_label_set_markup(
      titleLabel, "<b>\(PangoMarkup.escape(AutoPasteStartupPromptPresentation.title))</b>")
    gtk_box_append(box, titleLabel)

    Self.addWrappedLabel(to: box, text: AutoPasteStartupPromptPresentation.explanationText)
    Self.addWrappedLabel(to: box, text: AutoPasteStartupPromptPresentation.securityExplanationText)
    Self.addWrappedLabel(to: box, text: AutoPasteStartupPromptPresentation.reloginText)

    let statusLabel: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_xalign(statusLabel, 0)
    gtk_label_set_wrap(statusLabel, 1)
    gtk_label_set_max_width_chars(statusLabel, AutoPasteStartupPrompt.wrapWidthChars)
    gtk_widget_set_visible(statusLabel, 0)
    gtk_box_append(box, statusLabel)
    self.statusLabel = statusLabel

    let buttonBox: OpaquePointer = gtk_box_new(
      GTK_ORIENTATION_HORIZONTAL, AutoPasteStartupPrompt.spacing)
    gtk_widget_set_halign(buttonBox, GTK_ALIGN_END)

    let notNowButton: OpaquePointer = gtk_button_new_with_label(
      AutoPasteStartupPromptPresentation.notNowButtonLabel)
    let grantButton: OpaquePointer = gtk_button_new_with_label(
      AutoPasteStartupPromptPresentation.grantButtonLabel)
    gtk_widget_add_css_class(grantButton, "suggested-action")
    let closeButton: OpaquePointer = gtk_button_new_with_label(
      AutoPasteStartupPromptPresentation.closeButtonLabel)
    gtk_widget_set_visible(closeButton, 0)
    self.notNowButton = notNowButton
    self.grantButton = grantButton
    self.closeButton = closeButton

    gtk_box_append(buttonBox, notNowButton)
    gtk_box_append(buttonBox, grantButton)
    gtk_box_append(buttonBox, closeButton)
    gtk_box_append(box, buttonBox)

    gtk_window_set_child(window, box)

    connectSignals()
  }

  @discardableResult
  private static func addWrappedLabel(to box: OpaquePointer, text: String) -> OpaquePointer {
    let label: OpaquePointer = gtk_label_new(text)
    gtk_label_set_xalign(label, 0)
    gtk_label_set_wrap(label, 1)
    gtk_label_set_max_width_chars(label, AutoPasteStartupPrompt.wrapWidthChars)
    gtk_box_append(box, label)
    return label
  }

  private func connectSignals() {
    gtkConnect(
      notNowButton, signal: "clicked", context: self,
      callback: unsafeBitCast(autoPasteStartupPromptDismissClickedTrampoline, to: GCallback.self))
    gtkConnect(
      closeButton, signal: "clicked", context: self,
      callback: unsafeBitCast(autoPasteStartupPromptDismissClickedTrampoline, to: GCallback.self))
    gtkConnect(
      grantButton, signal: "clicked", context: self,
      callback: unsafeBitCast(autoPasteStartupPromptGrantClickedTrampoline, to: GCallback.self))
    gtkConnect(
      window, signal: "close-request", context: self,
      callback: unsafeBitCast(autoPasteStartupPromptCloseRequestTrampoline, to: GCallback.self))
  }

  @MainActor
  func present() {
    gtk_window_present(window)
  }

  /// "Not Now" and the "Close" button (shown post-outcome) both just close
  /// the dialog — see this file's top doc comment on why `isDismissed` is
  /// set here rather than only in `handleCloseRequest()`.
  @MainActor
  func dismiss() {
    guard !isDismissed else { return }
    isDismissed = true
    gtk_window_destroy(window)
  }

  /// `GtkWindow::close-request` (the titlebar X). Returning `0`
  /// (`GDK_EVENT_PROPAGATE`) lets GTK's default handling proceed to the real
  /// destroy — see `init`'s doc comment on why `hide_on_close` is
  /// deliberately not set. Records `isDismissed` itself rather than calling
  /// `dismiss()` (which would call `gtk_window_destroy` a second,
  /// unnecessary time on a window GTK is already in the middle of
  /// destroying).
  @MainActor
  func handleCloseRequest() -> Int32 {
    isDismissed = true
    return 0
  }

  @MainActor
  func handleGrantClicked() {
    gtk_widget_set_sensitive(notNowButton, 0)
    gtk_widget_set_sensitive(grantButton, 0)
    gtk_label_set_text(statusLabel, AutoPasteStartupPromptPresentation.grantInFlightStatusText)
    gtk_widget_set_visible(statusLabel, 1)
    requestUInputGrant { outcome in
      Task { @MainActor [weak self] in
        // `isDismissed` re-checked here, not just at click time — `pkexec`
        // blocks on the user's polkit answer, which can take far longer
        // than it takes the user to close this dialog first (titlebar X,
        // or simply not caring about the outcome anymore).
        guard let self, !self.isDismissed else { return }
        self.applyOutcome(outcome)
      }
    }
  }

  @MainActor
  private func applyOutcome(_ outcome: UInputGrantOutcome) {
    gtk_widget_set_visible(notNowButton, 0)
    gtk_widget_set_visible(grantButton, 0)
    gtk_widget_set_visible(closeButton, 1)
    switch outcome {
    case .succeeded(let message):
      gtk_label_set_text(
        statusLabel, AutoPasteStartupPromptPresentation.succeededStatusText(message: message))
    case .failed(let message):
      gtk_label_set_text(
        statusLabel, AutoPasteStartupPromptPresentation.failedStatusText(message: message))
    }
  }
}

/// `GtkButton::clicked` (Not Now / Close) — `void (*)(GtkButton*, gpointer)`.
/// Shared by both buttons: they perform the exact same action.
private let autoPasteStartupPromptDismissClickedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let session = unretainedContext(data, as: AutoPasteStartupPromptSession.self) else {
        return
      }
      MainActor.assumeIsolated { session.dismiss() }
    }

/// `GtkButton::clicked` (Grant Access…) — `void (*)(GtkButton*, gpointer)`.
private let autoPasteStartupPromptGrantClickedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let session = unretainedContext(data, as: AutoPasteStartupPromptSession.self) else {
        return
      }
      MainActor.assumeIsolated { session.handleGrantClicked() }
    }

/// `GtkWindow::close-request` — `gboolean (*)(GtkWindow*, gpointer)`.
private let autoPasteStartupPromptCloseRequestTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Int32 = { _, data in
      guard let session = unretainedContext(data, as: AutoPasteStartupPromptSession.self) else {
        return 0
      }
      return MainActor.assumeIsolated { session.handleCloseRequest() }
    }
