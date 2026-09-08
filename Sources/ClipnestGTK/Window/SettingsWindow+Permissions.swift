// SettingsWindow+Permissions.swift
//
// T-OPT3 (routed, P1 — raised from P2 by the competitor analysis at
// `docs/competitive-analysis.md`: "the single highest-value, cheapest fix"):
// the Linux analogue of macOS's Permissions tab (Accessibility grant +
// "Open System Settings"). Linux has no equivalent OS-level permission
// dialog to deep-link into — the analogue here is the `clipnest-input`
// uinput grant, which already ships end to end (the helper binary, its
// polkit policy, and the udev rule — see `packaging/linux/scripts
// /clipnest-grant-input`, `packaging/linux/polkit
// /app.clipnest.grant-input.policy`, `packaging/linux/udev
// /clipnest-uinput.rules`) but had ZERO call sites anywhere in `Sources/`
// before this task, so a user could never actually grant it and the uinput
// paste tier was permanently unreachable.
//
// This file owns the tab's presentation ONLY (widget building + wiring).
// The two collaborators it needs — reading the CURRENT real grant state,
// and invoking the privileged helper — cross the `ClipnestGTK` ->
// `ClipnestLinuxAppKit` module boundary as plain closures injected into
// `SettingsWindow.init` (see that type's `uinputPermissionStatusProvider`/
// `requestUInputGrant` doc comments), the same pattern already used for
// `launchAtLoginProvider`/`setLaunchAtLogin`/`reinstallToggleHotkeyFloor` —
// `ClipnestGTK` sits BELOW `ClipnestLinuxAppKit` in the dependency graph and
// cannot import it. `LinuxAppEnvironment.init` (`ClipnestLinuxAppKit`) is
// the composition root that supplies the real implementations
// (`UInputPermissionChecker`/`GrantInputHelperClient`, both new files in
// that module).
//
// Deliberately NO default value on either injected closure — see
// `SettingsWindow.reinstallToggleHotkeyFloor`'s doc comment for why: a
// `{ _ in }`/no-op default lets a missing composition-root wiring compile
// silently (exactly what happened to `PickerViewModel.presentSnippetEditor`
// once already). A required parameter turns that class of mistake into a
// build error here too.
import CGtk4

/// The uinput auto-paste grant's CURRENT, freshly-read state — two
/// independent booleans, not one combined flag, because they can and do
/// disagree in exactly one well-understood way: `usermod -aG` (run by
/// `clipnest-grant-input` under `pkexec`) updates the on-disk group
/// database immediately, but Linux only resolves a process's supplementary
/// groups at login time — so right after a successful grant,
/// `isInClipnestInputGroup` is already `true` while `isUInputAccessible`
/// stays `false` until the user logs out and back in. That gap is exactly
/// what this tab's re-login note (`PermissionsTabPresentation
/// .showsReloginNote`) exists to explain, not hide — showing a single
/// "granted: yes/no" flag would either lie about the re-login requirement
/// or hide that the grant genuinely took effect on disk.
public struct UInputPermissionStatus: Equatable, Sendable {
  public let isUInputAccessible: Bool
  public let isInClipnestInputGroup: Bool

  public init(isUInputAccessible: Bool, isInClipnestInputGroup: Bool) {
    self.isUInputAccessible = isUInputAccessible
    self.isInClipnestInputGroup = isInClipnestInputGroup
  }
}

/// The result of one `pkexec clipnest-grant-input` attempt (see
/// `GrantInputHelperClient`, `ClipnestLinuxAppKit`) — surfaced to the tab so
/// a failure or a cancelled polkit authentication dialog is shown to the
/// user rather than swallowed. Deliberately not a richer enum distinguishing
/// "cancelled" from "denied" from "helper failed": `pkexec`'s own exit codes
/// don't reliably distinguish those either (1/2/3/127 per `pkexec(1)`, and
/// this project's own container verification confirms an unattended
/// environment with no polkit authentication agent fails before even
/// reaching that distinction) — `message` carries whatever `pkexec`/the
/// helper actually said on stderr (or stdout on success), which is already
/// the more specific and honest text in every case.
/// Completion handed to `SettingsWindow.requestUInputGrant`.
///
/// Named rather than spelled inline because the inline form pushed
/// `SettingsWindow.init`'s parameter past 100 columns, and the two
/// swift-format versions in use disagree about how to wrap an `@escaping`
/// closure-type parameter: swift-format `main` (the CI image,
/// `swift:6.0-jammy`) accepted the wrapped form that Apple's 6.3.0 on macOS
/// rejected with `[LineLength]`. Two reviewers reached opposite verdicts on
/// the same line for exactly that reason. A typealias keeps the declaration
/// short enough that neither version has to wrap it.
public typealias UInputGrantCompletion = @Sendable (UInputGrantOutcome) -> Void

public enum UInputGrantOutcome: Equatable, Sendable {
  case succeeded(message: String)
  case failed(message: String)
}

/// Pure presentation logic for the Permissions tab — separated from GTK
/// widget code, mirroring `SnippetFormValidation`'s identical split, so the
/// actual decisions ("when is the re-login note shown," "when is the Grant
/// button visible") are unit-tested directly rather than only reachable
/// through a live widget tree.
public enum PermissionsTabPresentation {
  /// Whether the Grant button should still be offered. `.granted` hides it
  /// entirely (mirrors `SettingsWindow+History.swift`'s
  /// `pollOCRBackfillTick()`: nothing left to do renders as no button, not
  /// a disabled one) — `.pendingRelogin` also hides it (re-running the grant
  /// changes nothing further; the only remaining step is the user's own
  /// re-login), leaving it visible only in `.available`.
  public enum GrantAvailability: Equatable, Sendable {
    case available
    case pendingRelogin
    case granted
  }

  public static func availability(for status: UInputPermissionStatus) -> GrantAvailability {
    if status.isUInputAccessible { return .granted }
    if status.isInClipnestInputGroup { return .pendingRelogin }
    return .available
  }

  public static func grantButtonVisible(for status: UInputPermissionStatus) -> Bool {
    availability(for: status) == .available
  }

  /// The re-login note is shown in exactly the gap `UInputPermissionStatus`'s
  /// doc comment describes: on disk (group database) but not yet live in any
  /// running process's own supplementary groups.
  public static func showsReloginNote(for status: UInputPermissionStatus) -> Bool {
    availability(for: status) == .pendingRelogin
  }

  public static func uinputAccessibleLine(for status: UInputPermissionStatus) -> String {
    "/dev/uinput accessible right now: \(status.isUInputAccessible ? "Yes" : "No")"
  }

  public static func groupMembershipLine(for status: UInputPermissionStatus) -> String {
    "In the clipnest-input group: \(status.isInClipnestInputGroup ? "Yes" : "No")"
  }

  public static let reloginNoteText =
    "You're already in the clipnest-input group, but Linux only applies new group "
    + "membership at login — log out and back in for auto-paste to start working."

  public static let grantedConfirmationText =
    "Auto-paste input access is granted."

  public static let explanationText =
    "Auto-paste lets Clipnest type a copied item directly into whatever app you're "
    + "focused on, right after you pick it. Without this, Clipnest still copies the "
    + "item to your clipboard — you paste it yourself (Ctrl+V), same as most "
    + "clipboard managers on Linux. That's the normal, expected state, not an error."

  public static let securityExplanationText =
    "Auto-paste needs access to /dev/uinput to simulate a keystroke. Granting it adds "
    + "you to a dedicated \"clipnest-input\" group that can only create a virtual "
    + "input device — not the broader \"input\" group some similar tools use, which "
    + "also grants read access to every real keystroke and mouse movement on the "
    + "machine."

  public static let grantButtonLabel = "Grant Access…"
  public static let grantInFlightStatusText = "Waiting for authentication…"
}

extension SettingsWindow {
  /// Column width every wrapped explanatory label in this tab uses — matches
  /// `SettingsWindow+Shortcuts.swift`'s identical fix (an unwrapped
  /// `GtkLabel` forces the whole ~480px Settings window to stretch to fit
  /// one line; found there via runtime screenshot verification, applied
  /// here from the start rather than re-discovering it).
  static let permissionsExplanationWrapWidthChars: Int32 = 52

  @MainActor
  func buildPermissionsTab() {
    let box = appendTab(title: "Permissions")

    addWrappedLabel(to: box, text: PermissionsTabPresentation.explanationText)
    addWrappedLabel(to: box, text: PermissionsTabPresentation.securityExplanationText)

    let uinputStatusLabel: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_xalign(uinputStatusLabel, 0)
    gtk_box_append(box, uinputStatusLabel)
    permissionsUInputStatusLabel = uinputStatusLabel

    let groupStatusLabel: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_xalign(groupStatusLabel, 0)
    gtk_box_append(box, groupStatusLabel)
    permissionsGroupStatusLabel = groupStatusLabel

    let reloginNoteLabel = addWrappedLabel(
      to: box, text: PermissionsTabPresentation.reloginNoteText)
    gtk_widget_add_css_class(reloginNoteLabel, "dim-label")
    permissionsReloginNoteLabel = reloginNoteLabel

    let resultLabel = addStatusLabel(to: box)
    permissionsResultLabel = resultLabel

    let grantButton = addButton(to: box, label: PermissionsTabPresentation.grantButtonLabel) {
      [weak self] in
      MainActor.assumeIsolated {
        self?.requestUInputGrantFromUI()
      }
    }
    permissionsGrantButton = grantButton

    // T-WB1-GTKBUMP: the clipboard-stability notice — see
    // `GTKClipboardCrashNoticePresentation`'s doc comment for the full
    // root-cause/scope. Resolved once, here, from the composition-root-
    // supplied `gtkClipboardCrashNoticeInfo`, which cannot change for this
    // process's lifetime — unlike the uinput grant state above, there is
    // nothing here for `refreshPermissionsStatus()` to ever re-check, so
    // this section is built (or not built at all) exactly once, rather
    // than built-and-toggled on every `show()`.
    if GTKClipboardCrashNoticePresentation.shouldShow(for: gtkClipboardCrashNoticeInfo) {
      buildGTKClipboardCrashNoticeSection(in: box)
    }

    refreshPermissionsStatus()
  }

  /// Builds the clipboard-stability notice's title + wrapped body label,
  /// appended after every other Permissions-tab control — a distinct,
  /// visually separated section (its own bold-ish title line) rather than
  /// blended into the uinput-grant copy above, since the two are unrelated
  /// Linux-specific limitations that happen to share this tab. Only ever
  /// called when `GTKClipboardCrashNoticePresentation.shouldShow(for:)` is
  /// true (see `buildPermissionsTab()`), so every widget it creates is
  /// unconditionally shown — there is no runtime state transition that
  /// would need this section to later hide itself.
  @MainActor
  private func buildGTKClipboardCrashNoticeSection(in box: OpaquePointer) {
    let titleLabel: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_xalign(titleLabel, 0)
    // Bold via Pango markup, not a `heading`/`title` CSS class — GTK4's own
    // documented style classes (`.dim-label`/`.flat`/`.destructive-action`/
    // `.suggested-action`, all already in use elsewhere in this file/
    // module) don't include one for "bold label text"; `SnippetEditorWindow
    // .swift`'s `headingLabel` uses this exact `<b>` + `PangoMarkup.escape`
    // pattern for the identical need, escaped even though this particular
    // string is a compile-time constant (matches that call site's
    // discipline rather than assuming a literal can never need escaping).
    gtk_label_set_markup(
      titleLabel, "<b>\(PangoMarkup.escape(GTKClipboardCrashNoticePresentation.title))</b>")
    gtk_box_append(box, titleLabel)
    gtkClipboardCrashNoticeTitleLabel = titleLabel

    // No `dim-label` here (unlike `reloginNoteLabel` above): that class is
    // for a de-emphasized aside once a task is already mostly done; this
    // notice is safety-relevant information that should read with the same
    // full-contrast weight as `explanationText`/`securityExplanationText`
    // above, not look like a disabled/secondary hint.
    let bodyLabel = addWrappedLabel(
      to: box,
      text: GTKClipboardCrashNoticePresentation.bodyText(for: gtkClipboardCrashNoticeInfo))
    gtkClipboardCrashNoticeBodyLabel = bodyLabel
  }

  /// A wrapped, left-aligned label — the shared shape every explanatory
  /// paragraph in this tab uses (see `permissionsExplanationWrapWidthChars`'s
  /// doc comment for why wrapping is mandatory here, unlike most of this
  /// window's short single-line labels).
  @discardableResult
  private func addWrappedLabel(to box: OpaquePointer, text: String) -> OpaquePointer {
    let label: OpaquePointer = gtk_label_new(text)
    gtk_label_set_xalign(label, 0)
    gtk_label_set_wrap(label, 1)
    gtk_label_set_max_width_chars(label, SettingsWindow.permissionsExplanationWrapWidthChars)
    gtk_box_append(box, label)
    return label
  }

  /// Re-reads the real, current grant state and reconciles every widget in
  /// this tab against it — called once at tab-build time and again every
  /// time Settings is shown (`show()`), so a grant made in a previous
  /// session (after the required re-login) is reflected the next time the
  /// user opens Settings, without needing this permanent, app-lifetime
  /// window to poll continuously (this state changes only at login time or
  /// via this tab's own Grant button, never spontaneously while Settings is
  /// open — unlike, say, the OCR backfill row's genuinely async progress).
  @MainActor
  func refreshPermissionsStatus() {
    guard let permissionsUInputStatusLabel, let permissionsGroupStatusLabel,
      let permissionsReloginNoteLabel, let permissionsGrantButton
    else { return }

    let status = uinputPermissionStatusProvider()
    gtk_label_set_text(
      permissionsUInputStatusLabel, PermissionsTabPresentation.uinputAccessibleLine(for: status))
    gtk_label_set_text(
      permissionsGroupStatusLabel, PermissionsTabPresentation.groupMembershipLine(for: status))
    gtk_widget_set_visible(
      permissionsReloginNoteLabel, PermissionsTabPresentation.showsReloginNote(for: status) ? 1 : 0)
    gtk_widget_set_visible(
      permissionsGrantButton, PermissionsTabPresentation.grantButtonVisible(for: status) ? 1 : 0)
    gtk_widget_set_sensitive(permissionsGrantButton, 1)

    if let permissionsResultLabel {
      switch PermissionsTabPresentation.availability(for: status) {
      case .granted:
        setStatusLabel(
          permissionsResultLabel, text: PermissionsTabPresentation.grantedConfirmationText)
      case .pendingRelogin:
        // Clears any earlier failure/cancellation message from a prior
        // `.available`-state attempt — once the group database itself says
        // "already a member," a stale "couldn't grant access" from before
        // that would be actively misleading next to the dedicated re-login
        // note this state already shows.
        setStatusLabel(permissionsResultLabel, text: nil)
      case .available:
        // Leave whatever the last Grant attempt's own outcome message said
        // (e.g. a failure or cancellation) — the user may still want to see
        // why the last attempt didn't work while the button is available
        // again.
        break
      }
    }
  }

  /// `GtkButton::clicked` on "Grant Access…" — disables the button
  /// immediately (no double-invocation of `pkexec` from a second click
  /// while the first is still in flight) and shows a waiting indicator,
  /// then asks the composition root's `requestUInputGrant` closure to run
  /// `pkexec clipnest-grant-input` for real.
  @MainActor
  private func requestUInputGrantFromUI() {
    if let permissionsGrantButton {
      gtk_widget_set_sensitive(permissionsGrantButton, 0)
    }
    if let permissionsResultLabel {
      setStatusLabel(
        permissionsResultLabel, text: PermissionsTabPresentation.grantInFlightStatusText)
    }

    // `requestUInputGrant`'s own doc comment: `completion` may run on any
    // thread — the real implementation (`GrantInputHelperClient`,
    // `ClipnestLinuxAppKit`) calls it from a background `DispatchQueue`
    // while `pkexec` blocks waiting on the polkit authentication dialog
    // (or fails fast if none is available, e.g. this project's own
    // container verification). Hopping via `Task { @MainActor in ... }`
    // before touching any widget mirrors `SettingsWindow
    // +History.swift`'s `performClearHistory()` doing the identical hop
    // around its own async store call — pumped by `GTKMainActorBridge`/
    // `DispatchMainQueuePump` exactly the same way.
    requestUInputGrant { outcome in
      Task { @MainActor [weak self] in
        self?.applyGrantOutcome(outcome)
      }
    }
  }

  @MainActor
  private func applyGrantOutcome(_ outcome: UInputGrantOutcome) {
    if let permissionsResultLabel {
      switch outcome {
      case .succeeded(let message):
        setStatusLabel(permissionsResultLabel, text: message)
      case .failed(let message):
        setStatusLabel(permissionsResultLabel, text: "Couldn't grant access: \(message)")
      }
    }
    // Refresh from the real, current state rather than trusting `outcome`
    // alone — a `.succeeded` result only means the helper's `usermod`
    // itself ran; `refreshPermissionsStatus()` re-reads the group database
    // and `/dev/uinput` directly, which is what decides whether the
    // re-login note or the Grant button shows next. This also re-enables
    // the button when the availability is still `.available` (e.g. a
    // failed/cancelled attempt) — `.pendingRelogin`/`.granted` hide it
    // instead, which is itself the correct "re-enabled" outcome for those
    // states.
    refreshPermissionsStatus()
  }
}
